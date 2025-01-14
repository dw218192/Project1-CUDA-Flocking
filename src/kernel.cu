#define GLM_FORCE_CUDA

// stuff to help with intellisense
#ifdef __INTELLISENSE__
#define KERN_PARAM(x,y)
#include <device_launch_parameters.h>
#else
#define KERN_PARAM(x,y) <<< x,y >>>
#endif

// convenience macro
#define ALLOC(name, size) if(cudaMalloc((void**)&name, size * sizeof(*name)) != cudaSuccess) checkCUDAErrorWithLine("cudaMalloc" ## #name ## "failed!")
#define FREE(name) if(cudaFree(name) != cudaSuccess) checkCUDAErrorWithLine("cudaFree" ## #name ## "failed!")

// profiling

#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <glm/glm.hpp>
#include "utilityCore.hpp"
#include "kernel.h"

// LOOK-2.1 potentially useful for doing grid-based neighbor search
#ifndef imax
#define imax( a, b ) ( ((a) > (b)) ? (a) : (b) )
#endif

#ifndef imin
#define imin( a, b ) ( ((a) < (b)) ? (a) : (b) )
#endif

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)

/**
* Check for CUDA errors; print and exit if there was a problem.
*/
void checkCUDAError(const char *msg, int line = -1) {
  cudaError_t err = cudaGetLastError();
  if (cudaSuccess != err) {
    if (line >= 0) {
      fprintf(stderr, "Line %d: ", line);
    }
    fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
    exit(EXIT_FAILURE);
  }
}


/*****************
* Configuration *
*****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 128

// LOOK-1.2 Parameters for the boids algorithm.
// These worked well in our reference implementation.
#define rule1Distance 5.0f
#define rule2Distance 3.0f
#define rule3Distance 5.0f

#define rule1Scale 0.01f
#define rule2Scale 0.1f
#define rule3Scale 0.1f

#define maxSpeed 2.0f

/*! Size of the starting area in simulation space. */
#define scene_scale 100.0f


/* multiplier for the cell width */
#define cell_width_mul 2.0f

#include "profiling.h"

/***********************************************
* Kernel state (pointers are device pointers) *
***********************************************/

int numObjects;
dim3 threadsPerBlock(blockSize);

// LOOK-1.2 - These buffers are here to hold all your boid information.
// These get allocated for you in Boids::initSimulation.
// Consider why you would need two velocity buffers in a simulation where each
// boid cares about its neighbors' velocities.
// These are called ping-pong buffers.
glm::vec3 *dev_pos;
glm::vec3 *dev_vel1;
glm::vec3 *dev_vel2;

// LOOK-2.1 - these are NOT allocated for you. You'll have to set up the thrust
// pointers on your own too.

// For efficient sorting and the uniform grid. These should always be parallel.
int *dev_particleArrayIndices; // What index in dev_pos and dev_velX represents this particle?
int *dev_particleGridIndices; // What grid cell is this particle in?
// needed for use with thrust
thrust::device_ptr<int> dev_thrust_particleArrayIndices;
thrust::device_ptr<int> dev_thrust_particleGridIndices;

int *dev_gridCellStartIndices; // What part of dev_particleArrayIndices belongs
int *dev_gridCellEndIndices;   // to this cell?

// TODO-2.3 - consider what additional buffers you might need to reshuffle
// the position and velocity data to be coherent within cells.
glm::vec3* dev_coherentVel2;
glm::vec3* dev_coherentPos;

// LOOK-2.1 - Grid parameters based on simulation parameters.
// These are automatically computed for you in Boids::initSimulation
int gridCellCount;
int gridSideCount;
float gridCellWidth;
float gridInverseCellWidth;
glm::vec3 gridMinimum;

/******************
* initSimulation *
******************/

__host__ __device__ unsigned int hash(unsigned int a) {
  a = (a + 0x7ed55d16) + (a << 12);
  a = (a ^ 0xc761c23c) ^ (a >> 19);
  a = (a + 0x165667b1) + (a << 5);
  a = (a + 0xd3a2646c) ^ (a << 9);
  a = (a + 0xfd7046c5) + (a << 3);
  a = (a ^ 0xb55a4f09) ^ (a >> 16);
  return a;
}

/**
* LOOK-1.2 - this is a typical helper function for a CUDA kernel.
* Function for generating a random vec3.
*/
__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
  thrust::default_random_engine rng(hash((int)(index * time)));
  thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

  return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng), (float)unitDistrib(rng));
}

/**
* LOOK-1.2 - This is a basic CUDA kernel.
* CUDA kernel for generating boids with a specified mass randomly around the star.
*/
__global__ void kernGenerateRandomPosArray(int time, int N, glm::vec3 * arr, float scale) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    glm::vec3 rand = generateRandomVec3(time, index);
    arr[index].x = scale * rand.x;
    arr[index].y = scale * rand.y;
    arr[index].z = scale * rand.z;
  }
}

/**
* Initialize memory, update some globals
*/
void Boids::initSimulation(int N) {
  numObjects = N;
  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  // LOOK-1.2 - This is basic CUDA memory management and error checking.
  // Don't forget to cudaFree in  Boids::endSimulation.
  cudaMalloc((void**)&dev_pos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");

  cudaMalloc((void**)&dev_vel1, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel1 failed!");

  cudaMalloc((void**)&dev_vel2, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel2 failed!");

  // LOOK-1.2 - This is a typical CUDA kernel invocation.
  kernGenerateRandomPosArray KERN_PARAM(fullBlocksPerGrid,blockSize) (1, numObjects, dev_pos, scene_scale);
  checkCUDAErrorWithLine("kernGenerateRandomPosArray failed!");

  // LOOK-2.1 computing grid params
  gridCellWidth = cell_width_mul * std::max(std::max(rule1Distance, rule2Distance), rule3Distance);
  int halfSideCount = (int)(scene_scale / gridCellWidth) + 1;
  gridSideCount = 2 * halfSideCount;

  gridCellCount = gridSideCount * gridSideCount * gridSideCount;
  gridInverseCellWidth = 1.0f / gridCellWidth;
  float halfGridWidth = gridCellWidth * halfSideCount;
  gridMinimum.x -= halfGridWidth;
  gridMinimum.y -= halfGridWidth;
  gridMinimum.z -= halfGridWidth;

  // TODO-2.1 TODO-2.3 - Allocate additional buffers here.
  ALLOC(dev_particleArrayIndices, N);
  ALLOC(dev_particleGridIndices, N);
  ALLOC(dev_gridCellStartIndices, gridCellCount);
  ALLOC(dev_gridCellEndIndices, gridCellCount);

  dev_thrust_particleArrayIndices = thrust::device_ptr<int>{ dev_particleArrayIndices };
  dev_thrust_particleGridIndices = thrust::device_ptr<int>{ dev_particleGridIndices };

  // 2.3
  ALLOC(dev_coherentPos, N);
  ALLOC(dev_coherentVel2, N);

  cudaDeviceSynchronize();
}


/******************
* copyBoidsToVBO *
******************/

/**
* Copy the boid positions into the VBO so that they can be drawn by OpenGL.
*/
__global__ void kernCopyPositionsToVBO(int N, glm::vec3 *pos, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  float c_scale = -1.0f / s_scale;

  if (index < N) {
    vbo[4 * index + 0] = pos[index].x * c_scale;
    vbo[4 * index + 1] = pos[index].y * c_scale;
    vbo[4 * index + 2] = pos[index].z * c_scale;
    vbo[4 * index + 3] = 1.0f;
  }
}

__global__ void kernCopyVelocitiesToVBO(int N, glm::vec3 *vel, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  if (index < N) {
    vbo[4 * index + 0] = vel[index].x + 0.3f;
    vbo[4 * index + 1] = vel[index].y + 0.3f;
    vbo[4 * index + 2] = vel[index].z + 0.3f;
    vbo[4 * index + 3] = 1.0f;
  }
}

/**
* Wrapper for call to the kernCopyboidsToVBO CUDA kernel.
*/
void Boids::copyBoidsToVBO(float *vbodptr_positions, float *vbodptr_velocities) {
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  kernCopyPositionsToVBO KERN_PARAM(fullBlocksPerGrid, blockSize) (numObjects, dev_pos, vbodptr_positions, scene_scale);
  kernCopyVelocitiesToVBO KERN_PARAM(fullBlocksPerGrid, blockSize) (numObjects, dev_vel1, vbodptr_velocities, scene_scale);

  checkCUDAErrorWithLine("copyBoidsToVBO failed!");

  cudaDeviceSynchronize();
}


/******************
* stepSimulation *
******************/

/**
* LOOK-1.2 You can use this as a helper for kernUpdateVelocityBruteForce.
* __device__ code can be called from a __global__ context
* Compute the new velocity on the body with index `iSelf` due to the `N` boids
* in the `pos` and `vel` arrays.
*/
__device__ glm::vec3 computeVelocityChange(int N, int iSelf, const glm::vec3 *pos, const glm::vec3 *vel) {
  // Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
  // Rule 2: boids try to stay a distance d away from each other
  // Rule 3: boids try to match the speed of surrounding boids
    
    glm::vec3 perceived_center{ 0,0,0 },
        perceived_velocity{ 0,0,0 },
        rule2offset{ 0,0,0 };
    unsigned neighbor_cnts[2] = { 0,0 };

    for (int i = 0; i < N; ++i) {
        if (i == iSelf)
            continue;

        float dist = glm::distance(pos[i], pos[iSelf]);
        if (dist < rule1Distance) {
            perceived_center += pos[i];
            ++ neighbor_cnts[0];
        }
        if (dist < rule2Distance)
            rule2offset -= pos[i] - pos[iSelf];
        if (dist < rule3Distance) {
            perceived_velocity += vel[i];
            ++ neighbor_cnts[1];
        }
    }
    if (neighbor_cnts[0]) {
        perceived_center /= neighbor_cnts[0];
        perceived_center = (perceived_center - pos[iSelf]) * rule1Scale;
    }
        
    if (neighbor_cnts[1]) {
        perceived_velocity /= neighbor_cnts[1];
        perceived_velocity *= rule3Scale;
    }
    
    rule2offset *= rule2Scale;
    return perceived_center + rule2offset + perceived_velocity;
}

/**
* TODO-1.2 implement basic flocking
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdateVelocityBruteForce(int N, glm::vec3 *pos,
  glm::vec3 *vel1, glm::vec3 *vel2) {
  // Compute a new velocity based on pos and vel1
  // Clamp the speed
  // Record the new velocity into vel2. Question: why NOT vel1?
    int index = threadIdx.x + (blockIdx.x * blockDim.x);
    if (index >= N) {
        return;
    }
    glm::vec3 velocity = vel1[index] + computeVelocityChange(N, index, pos, vel1);
    
    // clamp
    float speed = glm::length(velocity);
    if (speed > maxSpeed) {
        velocity = velocity / speed * maxSpeed;
    }

    //store in vel2
    vel2[index] = velocity;
}

/**
* LOOK-1.2 Since this is pretty trivial, we implemented it for you.
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdatePos(int N, float dt, glm::vec3 *pos, glm::vec3 *vel) {
  // Update position by velocity
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  thisPos += vel[index] * dt;

  // Wrap the boids around so we don't lose them
  thisPos.x = thisPos.x < -scene_scale ? scene_scale : thisPos.x;
  thisPos.y = thisPos.y < -scene_scale ? scene_scale : thisPos.y;
  thisPos.z = thisPos.z < -scene_scale ? scene_scale : thisPos.z;

  thisPos.x = thisPos.x > scene_scale ? -scene_scale : thisPos.x;
  thisPos.y = thisPos.y > scene_scale ? -scene_scale : thisPos.y;
  thisPos.z = thisPos.z > scene_scale ? -scene_scale : thisPos.z;

  pos[index] = thisPos;
}

// LOOK-2.1 Consider this method of computing a 1D index from a 3D grid index.
// LOOK-2.3 Looking at this method, what would be the most memory efficient
//          order for iterating over neighboring grid cells?
//          for(x)
//            for(y)
//             for(z)? Or some other order?
__device__ int gridIndex3Dto1D(int x, int y, int z, int gridResolution) {
  return x + y * gridResolution + z * gridResolution * gridResolution;
}


// given a position, return the 3D grid coordinate that the boid is in
__device__ glm::i32vec3 getGridIndex(glm::vec3 position, float inverseCellWidth, glm::vec3 gridMin) {
    glm::vec3 rel_pos = position - gridMin; // convert to grid local space
    rel_pos *= inverseCellWidth;
    assert(rel_pos.x >= 0 && rel_pos.y >= 0 && rel_pos.z >= 0);
    int x = static_cast<int>(std::floor(rel_pos.x));
    int y = static_cast<int>(std::floor(rel_pos.y));
    int z = static_cast<int>(std::floor(rel_pos.z));
    rel_pos = glm::i32vec3(x, y, z);
    return rel_pos;
}

__global__ void kernComputeIndices(int N, int gridResolution,
  glm::vec3 gridMin, float inverseCellWidth,
  glm::vec3 *pos, int *indices, int *gridIndices) {
    // TODO-2.1
    // - Label each boid with the index of its grid cell.
    // - Set up a parallel array of integer indices as pointers to the actual
    //   boid data in pos and vel1/vel2
    int index = threadIdx.x + (blockIdx.x * blockDim.x);
    if (index >= N) {
        return;
    }
    glm::i32vec3 grid_pos = getGridIndex(pos[index], inverseCellWidth, gridMin);
    indices[index] = index;
    gridIndices[index] = gridIndex3Dto1D(grid_pos.x, grid_pos.y, grid_pos.z, gridResolution);
    assert(gridIndices[index] >= 0 && gridIndices[index] < gridResolution * gridResolution * gridResolution);
}

// LOOK-2.1 Consider how this could be useful for indicating that a cell
//          does not enclose any boids
__global__ void kernResetIntBuffer(int N, int *intBuffer, int value) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    intBuffer[index] = value;
  }
}

__global__ void kernIdentifyCellStartEnd(int N, int *particleGridIndices,
  int *gridCellStartIndices, int *gridCellEndIndices) {
  // TODO-2.1
  // Identify the start point of each cell in the gridIndices array.
  // This is basically a parallel unrolling of a loop that goes
  // "this index doesn't match the one before it, must be a new cell!"
    int index = (blockIdx.x * blockDim.x) + threadIdx.x;
    if (index >= N) {
        return;
    }

    if (!index || particleGridIndices[index - 1] != particleGridIndices[index]) {
        gridCellStartIndices[particleGridIndices[index]] = index;
    }
    if (index == N - 1 || particleGridIndices[index + 1] != particleGridIndices[index]) {
        gridCellEndIndices[particleGridIndices[index]] = index + 1; // I use half-open intervals
    }
}

// given a boid, return the neighboring cells that possibly contain the neighbors of this boid
__device__ void genNeighborCells(glm::vec3 boid_pos, glm::i32vec3 grid_pos, glm::vec3 gridMin, float cellWidth, glm::i32vec3(*out_positions)[8]) {
    glm::vec3 grid_center = grid_pos;
    grid_center *= cellWidth;
    boid_pos -= gridMin; // work in grid local space

    int deltas[3][2];

    for (int i = 0; i < 3; ++i) {
        deltas[i][0] = 0;
        deltas[i][1] = boid_pos[i] > grid_center[i] ? 1 : -1;
    }

    int k = 0;
    // zcx for the best spatial locality, due to the way gridIndex3Dto1D is computed
    for (int z : deltas[2]) {
        for (int y : deltas[1]) {
            for (int x : deltas[0]) {
                (*out_positions)[k++] = grid_pos + glm::i32vec3(x, y, z);
            }
        }
    }
}

__global__ void kernUpdateVelNeighborSearchScattered(
    int N, int gridResolution, glm::vec3 gridMin,
    float inverseCellWidth, float cellWidth,
    int* gridCellStartIndices, int* gridCellEndIndices,
    int* particleArrayIndices,
    glm::vec3* pos, glm::vec3* vel1, glm::vec3* vel2) {
    // TODO-2.1 - Update a boid's velocity using the uniform grid to reduce
    // the number of boids that need to be checked.
    // - Identify the grid cell that this particle is in
    // - Identify which cells may contain neighbors. This isn't always 8.
    // - For each cell, read the start/end indices in the boid pointer array.
    // - Access each boid in the cell and compute velocity change from
    //   the boids rules, if this boid is within the neighborhood distance.
    // - Clamp the speed change before putting the new speed in vel2
    int index = threadIdx.x + (blockIdx.x * blockDim.x);
    if (index >= N) {
        return;
    }

    int num_grids = gridResolution * gridResolution * gridResolution;
    glm::i32vec3 grid_pos = getGridIndex(pos[index], inverseCellWidth, gridMin);

    // rule calculation variables
    glm::vec3 perceived_center{ 0,0,0 },
        perceived_velocity{ 0,0,0 },
        rule2offset{ 0,0,0 };
    unsigned neighbor_cnts[2] = { 0,0 };

#ifdef IMPL_8 // the 8-cell neighbor search
    glm::i32vec3 neighbor_cells[8];
    genNeighborCells(pos[index], grid_pos, gridMin, cellWidth, &neighbor_cells);
    for (glm::i32vec3 const& npos : neighbor_cells) {
#else // 27-cell neighbor search
    for (int dx = -1; dx <= 1; ++dx) {
    for (int dy = -1; dy <= 1; ++dy) {
    for (int dz = -1; dz <= 1; ++dz) {
        glm::i32vec3 npos = grid_pos + glm::i32vec3(dx, dy, dz);
#endif
        int grid_index = gridIndex3Dto1D(npos.x, npos.y, npos.z, gridResolution);
        if (grid_index >= 0 && grid_index < num_grids) {
            int start = gridCellStartIndices[grid_index];
            int end = gridCellEndIndices[grid_index];

            for (int j = start; j < end; ++j) {
                int i = particleArrayIndices[j];
                if (i != index) {
                    float dist = glm::distance(pos[i], pos[index]);
                    if (dist < rule1Distance) {
                        perceived_center += pos[i];
                        ++neighbor_cnts[0];
                    }
                    if (dist < rule2Distance)
                        rule2offset -= pos[i] - pos[index];
                    if (dist < rule3Distance) {
                        perceived_velocity += vel1[i];
                        ++neighbor_cnts[1];
                    }
                }
            }
        }
#ifdef IMPL_8
    }
#else
    }}}
#endif

    if (neighbor_cnts[0]) {
        perceived_center /= neighbor_cnts[0];
        perceived_center = (perceived_center - pos[index]) * rule1Scale;
    }
    if (neighbor_cnts[1]) {
        perceived_velocity /= neighbor_cnts[1];
        perceived_velocity *= rule3Scale;
    }
    rule2offset *= rule2Scale;
    glm::vec3 velocity = vel1[index] + perceived_center + rule2offset + perceived_velocity;

    // clamp
    float speed = glm::length(velocity);
    if (speed > maxSpeed) {
        velocity = velocity / speed * maxSpeed;
    }

    //store in vel2
    vel2[index] = velocity;
}

__global__ void kernUpdateVelNeighborSearchCoherent(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // TODO-2.3 - This should be very similar to kernUpdateVelNeighborSearchScattered,
  // except with one less level of indirection.
  // This should expect gridCellStartIndices and gridCellEndIndices to refer
  // directly to pos and vel1.
  // - Identify the grid cell that this particle is in
  // - Identify which cells may contain neighbors. This isn't always 8.
  // - For each cell, read the start/end indices in the boid pointer array.
  //   DIFFERENCE: For best results, consider what order the cells should be
  //   checked in to maximize the memory benefits of reordering the boids data.
  // - Access each boid in the cell and compute velocity change from
  //   the boids rules, if this boid is within the neighborhood distance.
  // - Clamp the speed change before putting the new speed in vel2
    int index = threadIdx.x + (blockIdx.x * blockDim.x);
    if (index >= N) {
        return;
    }

    int num_grids = gridResolution * gridResolution * gridResolution;
    glm::i32vec3 grid_pos = getGridIndex(pos[index], inverseCellWidth, gridMin);

    // rule calculation variables
    glm::vec3 perceived_center{ 0,0,0 },
        perceived_velocity{ 0,0,0 },
        rule2offset{ 0,0,0 };
    unsigned neighbor_cnts[2] = { 0,0 };

#ifdef IMPL_8 // the 8-cell neighbor search
    glm::i32vec3 neighbor_cells[8];
    genNeighborCells(pos[index], grid_pos, gridMin, cellWidth, &neighbor_cells);
    for (glm::i32vec3 const& npos : neighbor_cells) {
#else // the 27-cell neighbor search
    for (int dx = -1; dx <= 1; ++dx) {
    for (int dy = -1; dy <= 1; ++dy) {
    for (int dz = -1; dz <= 1; ++dz) {
        glm::i32vec3 npos = grid_pos + glm::i32vec3(dx, dy, dz);
#endif
        int grid_index = gridIndex3Dto1D(npos.x, npos.y, npos.z, gridResolution);
        if (grid_index >= 0 && grid_index < num_grids) {
            int start = gridCellStartIndices[grid_index];
            int end = gridCellEndIndices[grid_index];

            for (int i = start; i < end; ++i) {
                // only difference: i is used directly to index pos & vel arrays
                if (i != index) {
                    float dist = glm::distance(pos[i], pos[index]);
                    if (dist < rule1Distance) {
                        perceived_center += pos[i];
                        ++neighbor_cnts[0];
                    }
                    if (dist < rule2Distance)
                        rule2offset -= pos[i] - pos[index];
                    if (dist < rule3Distance) {
                        perceived_velocity += vel1[i];
                        ++neighbor_cnts[1];
                    }
                }
            }
        }
#ifdef IMPL_8
    }
#else
    }}}
#endif

    if (neighbor_cnts[0]) {
        perceived_center /= neighbor_cnts[0];
        perceived_center = (perceived_center - pos[index]) * rule1Scale;
    }
    if (neighbor_cnts[1]) {
        perceived_velocity /= neighbor_cnts[1];
        perceived_velocity *= rule3Scale;
    }
    rule2offset *= rule2Scale;
    glm::vec3 velocity = vel1[index] + perceived_center + rule2offset + perceived_velocity;

    // clamp
    float speed = glm::length(velocity);
    if (speed > maxSpeed) {
        velocity = velocity / speed * maxSpeed;
    }

    //store in vel2
    vel2[index] = velocity;
}

/**
* Fills coherent pos and vel arrays according to the particleArrayIndices
*/
__global__ void kernFillCoherentArrays(
    int N, int* particleArrayIndices,
    glm::vec3* coherentPos, glm::vec3* coherentVel,
    glm::vec3* pos, glm::vec3* vel) {
    int index = threadIdx.x + (blockIdx.x * blockDim.x);
    if (index >= N) {
        return;
    }
    coherentPos[index] = pos[particleArrayIndices[index]];
    coherentVel[index] = vel[particleArrayIndices[index]];
}

/**
* Reverse operation of the above
*/
__global__ void kernFillOriginalArrays(
    int N, int* particleArrayIndices,
    glm::vec3* pos, glm::vec3* vel,
    glm::vec3 const* coherentPos, glm::vec3 const* coherentVel) {
    int index = threadIdx.x + (blockIdx.x * blockDim.x);
    if (index >= N) {
        return;
    }
    pos[particleArrayIndices[index]] = coherentPos[index];
    vel[particleArrayIndices[index]] = coherentVel[index];
}
/**
* Step the entire N-body simulation by `dt` seconds.
*/
void Boids::stepSimulationNaive(float dt) {
  // TODO-1.2 - use the kernels you wrote to step the simulation forward in time.
  // TODO-1.2 ping-pong the velocity buffers
    dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

    kernUpdateVelocityBruteForce KERN_PARAM(fullBlocksPerGrid, blockSize) (numObjects, dev_pos, dev_vel1, dev_vel2);
    kernUpdatePos KERN_PARAM(fullBlocksPerGrid, blockSize) (numObjects, dt, dev_pos, dev_vel2);
    std::swap(dev_vel1, dev_vel2);
}

void Boids::stepSimulationScatteredGrid(float dt) {
  // TODO-2.1
  // Uniform Grid Neighbor search using Thrust sort.
  // In Parallel:
  // - label each particle with its array index as well as its grid index.
  //   Use 2x width grids.
  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  // - Perform velocity updates using neighbor search
  // - Update positions
  // - Ping-pong buffers as needed
    dim3 block_dim_obj((numObjects + blockSize - 1) / blockSize);

    kernComputeIndices KERN_PARAM(block_dim_obj, blockSize) 
        (numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, dev_pos, dev_particleArrayIndices, dev_particleGridIndices);
    
    // sort (group) particles by grid index
    thrust::sort_by_key(dev_thrust_particleGridIndices, dev_thrust_particleGridIndices + numObjects, dev_thrust_particleArrayIndices);

    dim3 block_dim_grid((gridCellCount + blockSize - 1) / blockSize);
    kernResetIntBuffer KERN_PARAM(block_dim_grid, blockSize) (gridCellCount, dev_gridCellStartIndices, -1);
    kernResetIntBuffer KERN_PARAM(block_dim_grid, blockSize) (gridCellCount, dev_gridCellEndIndices, -1);

    // identify start and end
    kernIdentifyCellStartEnd KERN_PARAM(block_dim_obj, blockSize)
        (numObjects, dev_particleGridIndices, dev_gridCellStartIndices, dev_gridCellEndIndices);

    // do velocity update
    kernUpdateVelNeighborSearchScattered KERN_PARAM(block_dim_obj, blockSize) 
        (numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, 
            gridCellWidth, dev_gridCellStartIndices, dev_gridCellEndIndices, dev_particleArrayIndices, dev_pos, dev_vel1, dev_vel2);
    
    kernUpdatePos KERN_PARAM(block_dim_obj, blockSize) (numObjects, dt, dev_pos, dev_vel2);
    
    std::swap(dev_vel1, dev_vel2);
}

void Boids::stepSimulationCoherentGrid(float dt) {
  // TODO-2.3 - start by copying Boids::stepSimulationNaiveGrid
  // Uniform Grid Neighbor search using Thrust sort on cell-coherent data.
  // In Parallel:
  // - Label each particle with its array index as well as its grid index.
  //   Use 2x width grids
  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  // - BIG DIFFERENCE: use the rearranged array index buffer to reshuffle all
  //   the particle data in the simulation array.
  //   CONSIDER WHAT ADDITIONAL BUFFERS YOU NEED
  // - Perform velocity updates using neighbor search
  // - Update positions
  // - Ping-pong buffers as needed. THIS MAY BE DIFFERENT FROM BEFORE.

    dim3 block_dim_obj((numObjects + blockSize - 1) / blockSize);

    kernComputeIndices KERN_PARAM(block_dim_obj, blockSize)
        (numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, dev_pos, dev_particleArrayIndices, dev_particleGridIndices);

    // sort (group) particles by grid index
    thrust::sort_by_key(dev_thrust_particleGridIndices, dev_thrust_particleGridIndices + numObjects, dev_thrust_particleArrayIndices);

    dim3 block_dim_grid((gridCellCount + blockSize - 1) / blockSize);
    kernResetIntBuffer KERN_PARAM(block_dim_grid, blockSize) (gridCellCount, dev_gridCellStartIndices, -1);
    kernResetIntBuffer KERN_PARAM(block_dim_grid, blockSize) (gridCellCount, dev_gridCellEndIndices, -1);

    // identify start and end
    kernIdentifyCellStartEnd KERN_PARAM(block_dim_obj, blockSize)
        (numObjects, dev_particleGridIndices, dev_gridCellStartIndices, dev_gridCellEndIndices);

    // shuffle to make vel and pos coherent
    
    // some aliases to improve readability, hopefully...
    glm::vec3* dev_coherentVel1 = dev_vel2;

    kernFillCoherentArrays KERN_PARAM(block_dim_obj, blockSize)
        (numObjects, dev_particleArrayIndices, dev_coherentPos, dev_coherentVel1, dev_pos, dev_vel1);

    // do velocity update
    kernUpdateVelNeighborSearchCoherent KERN_PARAM(block_dim_obj, blockSize)
        (numObjects, gridSideCount, gridMinimum, gridInverseCellWidth,
            gridCellWidth, dev_gridCellStartIndices, dev_gridCellEndIndices, dev_coherentPos, dev_coherentVel1, dev_coherentVel2);
    
    kernUpdatePos KERN_PARAM(block_dim_obj, blockSize) (numObjects, dt, dev_coherentPos, dev_coherentVel2);

    // un-shuffle
    kernFillOriginalArrays KERN_PARAM(block_dim_obj, blockSize)
        (numObjects, dev_particleArrayIndices, dev_pos, dev_vel1, dev_coherentPos, dev_coherentVel2);

    // no need to ping-pong because of the extra buffers
}

void Boids::endSimulation() {
  FREE(dev_vel1);
  FREE(dev_vel2);
  FREE(dev_pos);

  // TODO-2.1 TODO-2.3 - Free any additional buffers here.
  FREE(dev_particleArrayIndices);
  FREE(dev_particleGridIndices);
  FREE(dev_gridCellStartIndices);
  FREE(dev_gridCellEndIndices);
  // 2.3
  FREE(dev_coherentPos);
  FREE(dev_coherentVel2);
}

void Boids::unitTest() {
  // LOOK-1.2 Feel free to write additional tests here.

  // kernel unit test Part 2
    {
        // I hate typing
#define PARAM(n) KERN_PARAM((n + blockSize - 1) / blockSize, blockSize)
#define H2D(stack_arr) cudaMemcpy(dev_##stack_arr, stack_arr, sizeof(stack_arr), cudaMemcpyHostToDevice)
#define D2H(stack_arr) cudaMemcpy(stack_arr, dev_##stack_arr, sizeof(stack_arr), cudaMemcpyDeviceToHost)

        constexpr int N_23 = 5;
        constexpr int M_23 = 10;

        // dev
        glm::vec3* dev_boid_vel;
        glm::vec3* dev_boid_pos;
        glm::vec3* dev_c_boid_vel;
        glm::vec3* dev_c_boid_pos;

        int* dev_grid_indices;
        int* dev_boid_indices;
        int* dev_grid_start;
        int* dev_grid_end;

        ALLOC(dev_boid_vel, N_23);
        ALLOC(dev_boid_pos, N_23);
        ALLOC(dev_c_boid_vel, N_23);
        ALLOC(dev_c_boid_pos, N_23);
        ALLOC(dev_grid_indices, N_23);
        ALLOC(dev_boid_indices, N_23);
        ALLOC(dev_grid_start, M_23);
        ALLOC(dev_grid_end, M_23);

        // host
        glm::vec3 boid_vel[N_23]{ {1,2,3},{4,5,6},{7,8,9},{10,11,12},{13,14,15} };
        glm::vec3 boid_pos[N_23]{ {1,2,3},{4,5,6},{7,8,9},{10,11,12},{13,14,15} };
        glm::vec3 c_boid_vel[N_23];
        glm::vec3 c_boid_pos[N_23];

        int grid_indices[N_23] { 4, 4, 5, 9, 9 };
        int boid_indices[N_23] { 0, 4, 1, 3, 2 };
        int grid_start[M_23];
        int grid_end[M_23];

        H2D(boid_vel);
        H2D(boid_pos);
        H2D(grid_indices);
        H2D(boid_indices);

        kernResetIntBuffer PARAM(M_23) (M_23, dev_grid_start, -1);
        kernResetIntBuffer PARAM(M_23) (M_23, dev_grid_end, -1);
        kernIdentifyCellStartEnd PARAM(N_23) (N_23, dev_grid_indices, dev_grid_start, dev_grid_end);
        kernFillCoherentArrays PARAM(N_23) (N_23, dev_boid_indices, dev_c_boid_pos, dev_c_boid_vel, dev_boid_pos, dev_boid_vel);

        D2H(grid_start);
        D2H(grid_end);
        D2H(c_boid_vel);
        D2H(c_boid_pos);
        
        std::cout << "start and end\n";
        for (int i = 0; i < M_23; i++) {
            std::cout << i << ": {" << grid_start[i] << "," << grid_end[i] << "}" << std::endl;
        }
        std::cout << "pos and vel\n";
        for (int i = 0; i < N_23; i++) {
            std::cout << i << ": {" << boid_vel[i].x << "," << boid_vel[i].y << "," << boid_vel[i].z << "} {"
                << boid_pos[i].x << "," << boid_pos[i].y << "," << boid_pos[i].z << "}" << std::endl;
        }
        std::cout << "coherent pos and vel\n";
        for (int i = 0; i < N_23; i++) {
            std::cout << i << ": {" << c_boid_vel[i].x << "," << c_boid_vel[i].y << "," << c_boid_vel[i].z << "} {"
                << c_boid_pos[i].x << "," << c_boid_pos[i].y << "," << c_boid_pos[i].z << "}" << std::endl;
        }

        memset(boid_pos, 0, sizeof(boid_pos));
        memset(boid_vel, 0, sizeof(boid_vel));

        H2D(boid_vel);
        H2D(boid_pos);
        kernFillOriginalArrays PARAM(N_23) (N_23, dev_boid_indices, dev_boid_pos, dev_boid_vel, dev_c_boid_pos, dev_c_boid_vel);
        D2H(boid_vel);
        D2H(boid_pos);

        std::cout << "pos and vel\n";
        for (int i = 0; i < N_23; i++) {
            std::cout << i << ": {" << boid_vel[i].x << "," << boid_vel[i].y << "," << boid_vel[i].z << "} {"
                << boid_pos[i].x << "," << boid_pos[i].y << "," << boid_pos[i].z << "}" << std::endl;
        }
#undef H2D
#undef D2H
#undef PARAM
    }

  // test unstable sort
  int *dev_intKeys;
  int *dev_intValues;
  int N = 10;

  std::unique_ptr<int[]>intKeys{ new int[N] };
  std::unique_ptr<int[]>intValues{ new int[N] };

  intKeys[0] = 0; intValues[0] = 0;
  intKeys[1] = 1; intValues[1] = 1;
  intKeys[2] = 0; intValues[2] = 2;
  intKeys[3] = 3; intValues[3] = 3;
  intKeys[4] = 0; intValues[4] = 4;
  intKeys[5] = 2; intValues[5] = 5;
  intKeys[6] = 2; intValues[6] = 6;
  intKeys[7] = 0; intValues[7] = 7;
  intKeys[8] = 5; intValues[8] = 8;
  intKeys[9] = 6; intValues[9] = 9;

  cudaMalloc((void**)&dev_intKeys, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intKeys failed!");

  cudaMalloc((void**)&dev_intValues, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intValues failed!");

  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  std::cout << "before unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // How to copy data to the GPU
  cudaMemcpy(dev_intKeys, intKeys.get(), sizeof(int) * N, cudaMemcpyHostToDevice);
  cudaMemcpy(dev_intValues, intValues.get(), sizeof(int) * N, cudaMemcpyHostToDevice);

  // Wrap device vectors in thrust iterators for use with thrust.
  thrust::device_ptr<int> dev_thrust_keys(dev_intKeys);
  thrust::device_ptr<int> dev_thrust_values(dev_intValues);
  // LOOK-2.1 Example for using thrust::sort_by_key
  thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + N, dev_thrust_values);

  // How to copy data back to the CPU side from the GPU
  cudaMemcpy(intKeys.get(), dev_intKeys, sizeof(int) * N, cudaMemcpyDeviceToHost);
  cudaMemcpy(intValues.get(), dev_intValues, sizeof(int) * N, cudaMemcpyDeviceToHost);
  checkCUDAErrorWithLine("memcpy back failed!");

  std::cout << "after unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // cleanup
  cudaFree(dev_intKeys);
  cudaFree(dev_intValues);
  checkCUDAErrorWithLine("cudaFree failed!");
  return;
}


#undef ALLOC