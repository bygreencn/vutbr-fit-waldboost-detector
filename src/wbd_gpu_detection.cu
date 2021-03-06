#include "wbd_gpu_detection.cuh"
#include "wbd_detector.h"

namespace wbd
{
	namespace gpu
	{
		namespace detection
		{
			void initDetectionStages()
			{
				cudaMemcpyToSymbol(stages, hostStages, sizeof(Stage) * WB_STAGE_COUNT);
			}

			__device__ void sumRegions(cudaTextureObject_t texture, float* values, float x, float y, Stage* stage)
			{
				values[0] = tex2D<float>(texture, x, y);
				x += stage->width;
				values[1] = tex2D<float>(texture, x, y);
				x += stage->width;
				values[2] = tex2D<float>(texture, x, y);
				y += stage->height;
				values[5] = tex2D<float>(texture, x, y);
				y += stage->height;
				values[8] = tex2D<float>(texture, x, y);
				x -= stage->width;
				values[7] = tex2D<float>(texture, x, y);
				x -= stage->width;
				values[6] = tex2D<float>(texture, x, y);
				y -= stage->height;
				values[3] = tex2D<float>(texture, x, y);
				x += stage->width;
				values[4] = tex2D<float>(texture, x, y);
			} // sumRegions

			__device__ float evalLBP(cudaTextureObject_t texture, cudaTextureObject_t alphas, uint32 x, uint32 y, Stage* stage)
			{
				const uint8 LBPOrder[8] = { 0, 1, 2, 5, 8, 7, 6, 3 };

				float values[9];

				sumRegions(texture, values, static_cast<float>(x)+(static_cast<float>(stage->width) * 0.5f), y + (static_cast<float>(stage->height) * 0.5f), stage);

				uint8 code = 0;
				for (uint8 i = 0; i < 8; ++i)
					code |= (values[LBPOrder[i]] > values[4]) << i;

				return tex1Dfetch<float>(alphas, stage->alphaOffset + code);
			} // evalLBP

			__device__ bool eval(cudaTextureObject_t texture, cudaTextureObject_t alphas, uint32 x, uint32 y, float* response, uint16 startStage, uint16 endStage)
			{
				for (uint16 i = startStage; i < endStage; ++i) {
					Stage stage = stages[i];
					*response += evalLBP(texture, alphas, x + stage.x, y + stage.y, &stage);
					if (*response < stage.thetaB) {
						return false;
					}
				}

				// final waldboost threshold
				return *response > WB_FINAL_THRESHOLD;
			} // eval

			namespace prefixsum
			{                
				__global__ void detectSurvivorsInit
				(
					cudaTextureObject_t texture,
					cudaTextureObject_t alphas,							
                    const uint32        width,
                    const uint32        height,
					SurvivorData*		survivors,
					uint32*				survivorCount,					
					uint16				endStage)
                {
                    extern __shared__ uint32 survivorScanArray[];                    
                    __shared__ uint32 survivorOffset;

                    const uint32 x = (blockIdx.x * blockDim.x) + threadIdx.x;
                    const uint32 y = (blockIdx.y * blockDim.y) + threadIdx.y;
                    const uint32 blockId = blockDim.x * threadIdx.y + threadIdx.x;
                    const uint32 blockSize = blockDim.x * blockDim.y;

                    float response = 0.0f;
                    
                    bool survived = false;

                    if (x < width && y < height)
                        survived = eval(texture, alphas, x, y, &response, 0, endStage);

                    survivorScanArray[blockId] = survived ? 1 : 0;

                    __syncthreads();

                    // up-sweep
                    uint32 offset = 1;
                    for (uint32 d = blockSize >> 1; d > 0; d >>= 1, offset <<= 1)
                    {
                        __syncthreads();

                        if (blockId < d)
                        {
                            const uint32 ai = offset * (2 * blockId + 1) - 1;
                            const uint32 bi = offset * (2 * blockId + 2) - 1;
                            survivorScanArray[bi] += survivorScanArray[ai];
                        }
                    }

                    // down-sweep
                    if (blockId == 0) {
                        survivorScanArray[blockSize - 1] = 0;
                    }

                    for (uint32 d = 1; d < blockSize; d <<= 1)
                    {
                        offset >>= 1;

                        __syncthreads();

                        if (blockId < d)
                        {
                            const uint32 ai = offset * (2 * blockId + 1) - 1;
                            const uint32 bi = offset * (2 * blockId + 2) - 1;

                            const uint32 t = survivorScanArray[ai];
                            survivorScanArray[ai] = survivorScanArray[bi];
                            survivorScanArray[bi] += t;
                        }
                    }

                    __syncthreads();
                    
                    if (blockId == 0) {
                        survivorOffset = atomicAdd(survivorCount, survivorScanArray[blockSize - 1]);                        
                    }

                    __syncthreads();

                    if (survived)
                    {
                        uint32 newThreadId = survivorOffset + survivorScanArray[blockId];

                        // save position and current response
                        survivors[newThreadId].x = x;
                        survivors[newThreadId].y = y;
                        survivors[newThreadId].response = response;
                    }                    
				}

                __global__ void detectSurvivors(
                    cudaTextureObject_t texture,
                    cudaTextureObject_t alphas,
                    SurvivorData*		survivorsStart,
                    SurvivorData*		survivorsEnd,
                    const uint32*		survivorCountStart,
                    uint32*				survivorCountEnd,
                    const uint16		startStage,
                    const uint16		endStage)
                {
                    extern __shared__ uint32 survivorScanArray[];
                    __shared__ uint32 survivorOffset;
                    
                    const uint32 threadId = (blockDim.x * gridDim.x) * (blockDim.y * blockIdx.y + threadIdx.y) + (blockDim.x * blockIdx.x + threadIdx.x);
                    const uint32 blockId = blockDim.x * threadIdx.y + threadIdx.x;
                    const uint32 blockSize = blockDim.x * blockDim.y;                

                    float response;
                    uint32 x, y;
                    bool survived = false;

                    if (blockId == 0)
                        survivorOffset = 0;

                    if (threadId < *survivorCountStart)
                    {
                        response = survivorsStart[threadId].response;
                        x = survivorsStart[threadId].x;
                        y = survivorsStart[threadId].y;

                        survived = eval(texture, alphas, x, y, &response, startStage, endStage);
                    }                                       

                    survivorScanArray[blockId] = survived ? 1 : 0;

                    __syncthreads();

                    // up-sweep
                    uint32 offset = 1;
                    for (uint32 d = blockSize >> 1; d > 0; d >>= 1, offset <<= 1)
                    {
                        __syncthreads();

                        if (blockId < d)
                        {
                            const uint32 ai = offset * (2 * blockId + 1) - 1;
                            const uint32 bi = offset * (2 * blockId + 2) - 1;
                            survivorScanArray[bi] += survivorScanArray[ai];
                        }
                    }

                    // down-sweep
                    if (blockId == 0) {
                        survivorScanArray[blockSize - 1] = 0;
                    }

                    for (uint32 d = 1; d < blockSize; d <<= 1)
                    {
                        offset >>= 1;

                        __syncthreads();

                        if (blockId < d)
                        {
                            const uint32 ai = offset * (2 * blockId + 1) - 1;
                            const uint32 bi = offset * (2 * blockId + 2) - 1;

                            const uint32 t = survivorScanArray[ai];
                            survivorScanArray[ai] = survivorScanArray[bi];
                            survivorScanArray[bi] += t;
                        }
                    }

                    __syncthreads();

                    if (blockId == 0) {
                        survivorOffset = atomicAdd(survivorCountEnd, survivorScanArray[blockSize - 1]);
                    }

                    __syncthreads();

                    if (survived)
                    {
                        uint32 newThreadId = survivorOffset + survivorScanArray[blockId];

                        // save position and current response
                        survivorsEnd[newThreadId].x = x;
                        survivorsEnd[newThreadId].y = y;
                        survivorsEnd[newThreadId].response = response;
                    }
				}

                __global__
                    void detectDetections(
                    cudaTextureObject_t texture,
                    cudaTextureObject_t alphas,
                    SurvivorData*		survivors,
                    const uint32*		survivorsCount,
                    Detection*			detections,
                    uint32*				detectionCount,
                    const uint16		startStage)
                {
                    extern __shared__ uint32 survivorScanArray[];
                    __shared__ uint32 detectionOffset;

                    const uint32 threadId = (blockDim.x * gridDim.x) * (blockDim.y * blockIdx.y + threadIdx.y) + (blockDim.x * blockIdx.x + threadIdx.x);
                    const uint32 blockId = blockDim.x * threadIdx.y + threadIdx.x;
                    const uint32 blockSize = blockDim.x * blockDim.y;

                    float response;
                    uint32 x, y;
                    bool survived = false;

                    if (blockId == 0)
                        detectionOffset = 0;

                    if (threadId < *survivorsCount)
                    {
                        response = survivors[threadId].response;
                        x = survivors[threadId].x;
                        y = survivors[threadId].y;

                        survived = eval(texture, alphas, x, y, &response, startStage, WB_STAGE_COUNT);
                    }

                    survivorScanArray[blockId] = survived ? 1 : 0;

                    __syncthreads();

                    // up-sweep
                    uint32 offset = 1;
                    for (uint32 d = blockSize >> 1; d > 0; d >>= 1, offset <<= 1)
                    {
                        __syncthreads();

                        if (blockId < d)
                        {
                            const uint32 ai = offset * (2 * blockId + 1) - 1;
                            const uint32 bi = offset * (2 * blockId + 2) - 1;
                            survivorScanArray[bi] += survivorScanArray[ai];
                        }
                    }

                    // down-sweep
                    if (blockId == 0) {
                        survivorScanArray[blockSize - 1] = 0;
                    }

                    for (uint32 d = 1; d < blockSize; d <<= 1)
                    {
                        offset >>= 1;

                        __syncthreads();

                        if (blockId < d)
                        {
                            const uint32 ai = offset * (2 * blockId + 1) - 1;
                            const uint32 bi = offset * (2 * blockId + 2) - 1;

                            const uint32 t = survivorScanArray[ai];
                            survivorScanArray[ai] = survivorScanArray[bi];
                            survivorScanArray[bi] += t;
                        }
                    }

                    __syncthreads();

                    if (blockId == 0) {
                        detectionOffset = atomicAdd(detectionCount, survivorScanArray[blockSize - 1]);
                    }

                    __syncthreads();

                    if (survived)
                    {
                        uint32 newThreadId = detectionOffset + survivorScanArray[blockId];

                        detections[newThreadId].x = x;
                        detections[newThreadId].y = y;
                        detections[newThreadId].width = WB_CLASSIFIER_WIDTH;
                        detections[newThreadId].height = WB_CLASSIFIER_HEIGHT;
                        detections[newThreadId].response = response;
                    }
				}
			} // namespace prefixsum

            namespace hybridsg
            {
                __global__
                    void detectSurvivorsInit(
                    cudaTextureObject_t texture,
                    cudaTextureObject_t alphas,
                    const uint32		width,
                    const uint32		height,
                    SurvivorData*		survivors,
                    uint32*				survivorCount,
                    const uint16		endStage)
                {                    
                    __shared__ uint32 localSurvivorCount;
                    __shared__ uint32 globalOffset;

                    const uint32 x = (blockIdx.x * blockDim.x) + threadIdx.x;
                    const uint32 y = (blockIdx.y * blockDim.y) + threadIdx.y;
                    const uint32 threadId = blockDim.x * threadIdx.y + threadIdx.x;                    

                    if (threadId == 0)
                        localSurvivorCount = 0;

                    __syncthreads();
                                        
                    float response = 0.0f;

                    bool survived = false;
                    uint32 newThreadId;

                    if (x < width - WB_CLASSIFIER_WIDTH && y < height - WB_CLASSIFIER_HEIGHT)
                    {
                        survived = eval(texture, alphas, x, y, &response, 0, endStage);
                        if (survived)
                            newThreadId = atomicInc(&localSurvivorCount, blockDim.x * blockDim.y);
                    }                                       

                    __syncthreads();

                    if (threadId == 0)        
                        globalOffset = atomicAdd(survivorCount, localSurvivorCount);

                    __syncthreads();

                    if (survived) 
                    {
                        newThreadId += globalOffset;

                        // save position and current response
                        survivors[newThreadId].x = x;
                        survivors[newThreadId].y = y;
                        survivors[newThreadId].response = response;
                    }                    
                }

                __global__ void detectSurvivors(
                    cudaTextureObject_t texture,
                    cudaTextureObject_t alphas,
                    SurvivorData*		survivorsStart,
                    SurvivorData*		survivorsEnd,
                    const uint32*		survivorCountStart,
                    uint32*				survivorCountEnd,
                    const uint16		startStage,
                    const uint16		endStage)
                {
                    __shared__ uint32 localSurvivorCount;
                    __shared__ uint32 globalOffset;

                    const uint32 threadId = (blockDim.x * gridDim.x) * (blockDim.y * blockIdx.y + threadIdx.y) + (blockDim.x * blockIdx.x + threadIdx.x);

                    if (threadIdx.x == 0 && threadIdx.y == 0)
                        localSurvivorCount = 0;

                    __syncthreads();

                    bool survived = false;
                    float response;
                    uint32 x, y, newThreadId;
                    if (threadId < *survivorCountStart)
                    {
                        response = survivorsStart[threadId].response;
                        x = survivorsStart[threadId].x;
                        y = survivorsStart[threadId].y;

                        survived = eval(texture, alphas, x, y, &response, startStage, endStage);
                        if (survived)
                            newThreadId = atomicInc(&localSurvivorCount, blockDim.x * blockDim.y);
                    }                                   

                    __syncthreads();

                    if (threadIdx.x == 0 && threadIdx.y == 0)
                        globalOffset = atomicAdd(survivorCountEnd, localSurvivorCount);

                    __syncthreads();

                    if (survived)
                    {
                        newThreadId += globalOffset;

                        // save position and current response
                        survivorsEnd[newThreadId].x = x;
                        survivorsEnd[newThreadId].y = y;
                        survivorsEnd[newThreadId].response = response;
                    }                    
                }

                __global__
                    void detectDetections(
                    cudaTextureObject_t texture,
                    cudaTextureObject_t alphas,
                    SurvivorData*		survivors,
                    const uint32*		survivorsCount,
                    Detection*			detections,
                    uint32*				detectionCount,
                    const uint16		startStage)
                {
                    __shared__ uint32 localDetectionCount;
                    __shared__ uint32 globalOffset;

                    const uint32 threadId = (blockDim.x * gridDim.x) * (blockDim.y * blockIdx.y + threadIdx.y) + (blockDim.x * blockIdx.x + threadIdx.x);

                    if (threadIdx.x == 0 && threadIdx.y == 0)
                        localDetectionCount = 0;

                    __syncthreads();

                    float response;
                    uint32 x, y, newThreadId;
                    bool survived = false;

                    if (threadId < *survivorsCount)
                    {
                        response = survivors[threadId].response;
                        x = survivors[threadId].x;
                        y = survivors[threadId].y;

                        survived = eval(texture, alphas, x, y, &response, startStage, WB_STAGE_COUNT);
                        if (survived)
                            newThreadId = atomicInc(&localDetectionCount, blockDim.x * blockDim.y);
                    }                                                                      

                    __syncthreads();

                    if (threadIdx.x == 0 && threadIdx.y == 0)                    
                        globalOffset = atomicAdd(detectionCount, localDetectionCount);

                    __syncthreads();

                    if (survived)
                    {
                        newThreadId += globalOffset;                      

                        detections[newThreadId].x = x;
                        detections[newThreadId].y = y;
                        detections[newThreadId].width = WB_CLASSIFIER_WIDTH;
                        detections[newThreadId].height = WB_CLASSIFIER_HEIGHT;
                        detections[newThreadId].response = response;                        
                    }
                }
            } // namespace hybridsg

			namespace atomicshared
			{
				__device__
					void detectSurvivorsInit(
					cudaTextureObject_t texture,
					cudaTextureObject_t alphas,
					uint32 const&	x,
					uint32 const&	y,
					uint32 const&	threadId,
					SurvivorData*	localSurvivors,
					uint32*			localSurvivorCount,
					uint16			endStage)
				{
					float response = 0.0f;
					bool survived = eval(texture, alphas, x, y, &response, 0, endStage);
					if (survived)
					{
						uint32 newThreadId = atomicInc(localSurvivorCount, blockDim.x * blockDim.y);
						// save position and current response
						localSurvivors[newThreadId].x = x;
						localSurvivors[newThreadId].y = y;
						localSurvivors[newThreadId].response = response;
					}
				}

				__device__ void detectSurvivors(
					cudaTextureObject_t texture,
					cudaTextureObject_t alphas,
					uint32 const&	threadId,
					SurvivorData*	localSurvivors,
					uint32*			localSurvivorCount,
					uint16			startStage,
					uint16			endStage)
				{
					float response = localSurvivors[threadId].response;
					const uint32 x = localSurvivors[threadId].x;
					const uint32 y = localSurvivors[threadId].y;

					bool survived = eval(texture, alphas, x, y, &response, startStage, endStage);
					if (survived)
					{
						uint32 newThreadId = atomicInc(localSurvivorCount, blockDim.x * blockDim.y);
						localSurvivors[newThreadId].x = x;
						localSurvivors[newThreadId].y = y;
						localSurvivors[newThreadId].response = response;
					}
				}

				__device__
					void detectDetections(
					cudaTextureObject_t texture,
					cudaTextureObject_t alphas,
					uint32 const&	threadId,
					SurvivorData*	localSurvivors,
					Detection*		detections,
					uint32*			detectionCount,
					uint16			startStage)
				{
					float response = localSurvivors[threadId].response;
					const uint32 x = localSurvivors[threadId].x;
					const uint32 y = localSurvivors[threadId].y;

					bool survived = eval(texture, alphas, x, y, &response, startStage, WB_STAGE_COUNT);
					if (survived)
					{
						uint32 pos = atomicInc(detectionCount, WB_MAX_DETECTIONS);
						detections[pos].x = x;
						detections[pos].y = y;
						detections[pos].width = WB_CLASSIFIER_WIDTH;
						detections[pos].height = WB_CLASSIFIER_HEIGHT;
						detections[pos].response = response;
					}
				}

				__global__ void detect(
					cudaTextureObject_t texture,
					cudaTextureObject_t alphas,
					uint32				width,
					uint32				height,
					Detection*			detections,
					uint32*				detectionCount)
				{
					extern __shared__ SurvivorData survivors[];
					__shared__ uint32 survivorCount;

					const uint32 x = (blockIdx.x * blockDim.x) + threadIdx.x;
					const uint32 y = (blockIdx.y * blockDim.y) + threadIdx.y;

					if (x < width - WB_CLASSIFIER_WIDTH && y < height - WB_CLASSIFIER_HEIGHT)
					{
						const uint32 threadId = threadIdx.y * blockDim.x + threadIdx.x;

						if (threadId == 0)
							survivorCount = 0;

						__syncthreads();

						detectSurvivorsInit(texture, alphas, x, y, threadId, survivors, &survivorCount, 1);

						__syncthreads();
                        if (threadId >= survivorCount)
                            return;
                        __syncthreads();					
						if (threadId == 0)
							survivorCount = 0;
						__syncthreads();

						detectSurvivors(texture, alphas, threadId, survivors, &survivorCount, 1, 8);

						__syncthreads();
						if (threadId >= survivorCount)
							return;
						__syncthreads();
						if (threadId == 0)
							survivorCount = 0;
						__syncthreads();

						detectSurvivors(texture, alphas, threadId, survivors, &survivorCount, 8, 64);

						__syncthreads();
						if (threadId >= survivorCount)
							return;
						__syncthreads();
						if (threadId == 0)
							survivorCount = 0;
						__syncthreads();

						detectSurvivors(texture, alphas, threadId, survivors, &survivorCount, 64, 256);

						__syncthreads();
						if (threadId >= survivorCount)
							return;
						__syncthreads();
						if (threadId == 0)
							survivorCount = 0;
						__syncthreads();

						detectSurvivors(texture, alphas, threadId, survivors, &survivorCount, 256, 512);

						__syncthreads();
						if (threadId >= survivorCount)
							return;
						__syncthreads();

						detectDetections(texture, alphas, threadId, survivors, detections, detectionCount, 512);
					}
				}

			} // namespace atomicshared

			namespace atomicglobal
			{
				__global__ void detectSurvivors(
					cudaTextureObject_t texture,
					cudaTextureObject_t alphas,						
					SurvivorData*		survivorsStart,
					SurvivorData*		survivorsEnd,
					const uint32*		survivorCountStart,
					uint32*				survivorCountEnd,
					const uint16		startStage,
					const uint16		endStage)
				{
					const uint32 threadId = (blockDim.x * gridDim.x) * (blockDim.y * blockIdx.y + threadIdx.y) + (blockDim.x * blockIdx.x + threadIdx.x);										

					if (threadId < *survivorCountStart)
					{
						float response = survivorsStart[threadId].response;
						const uint32 x = survivorsStart[threadId].x;
						const uint32 y = survivorsStart[threadId].y;

						bool survived = eval(texture, alphas, x, y, &response, startStage, endStage);
						if (survived)
						{
							uint32 newThreadId = atomicInc(survivorCountEnd, *survivorCountStart);
							survivorsEnd[newThreadId].x = x;
							survivorsEnd[newThreadId].y = y;
							survivorsEnd[newThreadId].response = response;
						}
					}
				}

				__global__
					void detectDetections(
					cudaTextureObject_t texture,
					cudaTextureObject_t alphas,					
					SurvivorData*		survivors,
					const uint32*		survivorsCount,
					Detection*			detections,
					uint32*				detectionCount,
					const uint16		startStage)
				{
					const uint32 threadId = (blockDim.x * gridDim.x) * (blockDim.y * blockIdx.y + threadIdx.y) + (blockDim.x * blockIdx.x + threadIdx.x);

					if (threadId < *survivorsCount)
					{
						float response = survivors[threadId].response;
						const uint32 x = survivors[threadId].x;
						const uint32 y = survivors[threadId].y;

						bool survived = eval(texture, alphas, x, y, &response, startStage, WB_STAGE_COUNT);
						if (survived)
						{
							uint32 pos = atomicInc(detectionCount, WB_MAX_DETECTIONS);
							detections[pos].x = x;
							detections[pos].y = y;
							detections[pos].width = WB_CLASSIFIER_WIDTH;
							detections[pos].height = WB_CLASSIFIER_HEIGHT;
							detections[pos].response = response;
						}
					}
				}

				__global__ void detectSurvivorsInit(
					cudaTextureObject_t texture,
					cudaTextureObject_t alphas,
					const uint32		width,
					const uint32		height,
					SurvivorData*		survivors,
					uint32*				survivorCount,
					const uint16		endStage)
				{
					const uint32 x = (blockIdx.x * blockDim.x) + threadIdx.x;
					const uint32 y = (blockIdx.y * blockDim.y) + threadIdx.y;					

					if (x < width - WB_CLASSIFIER_WIDTH && y < height - WB_CLASSIFIER_HEIGHT)
					{																		
						float response = 0.0f;
						bool survived = eval(texture, alphas, x, y, &response, 0, endStage);

						if (survived)
						{
							uint32 newThreadId = atomicInc(survivorCount, width * height);							
							survivors[newThreadId].x = x;
							survivors[newThreadId].y = y;
							survivors[newThreadId].response = response;
						}
					}
				}

			} // namespace atomicglobal

		} // namespace detection
	} // namespace gpu
} // namespace wbd
