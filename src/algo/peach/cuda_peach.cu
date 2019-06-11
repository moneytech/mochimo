/*
 * cuda_trigg.cu  Multi-GPU CUDA Mining
 *
 * Copyright (c) 2019 by Adequate Systems, LLC.  All Rights Reserved.
 * See LICENSE.PDF   **** NO WARRANTY ****
 *
 * Date: 10 August 2018
 * Revision: 31
 */

#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <unistd.h>
#include <cuda_runtime.h>
extern "C" {
#include "../../crypto/sha256.h"
}

#include "../../config.h"
#include "sha256.cuh"
#include "peach.h"

#define AS_UINT2(addr) *((uint2*)(addr))

// Define this to turn on error checking
#define CUDA_ERROR_CHECK

#define CudaSafeCall( err ) __cudaSafeCall( err, __FILE__, __LINE__ )
#define CudaCheckError()    __cudaCheckError( __FILE__, __LINE__ )

inline void __cudaSafeCall( cudaError err, const char *file, const int line )
{
#ifdef CUDA_ERROR_CHECK
    if ( cudaSuccess != err )
    {
        fprintf( stderr, "cudaSafeCall() failed at %s:%i : %s\n",
                 file, line, cudaGetErrorString( err ) );
        exit( -1 );
    }
#endif

    return;
}

inline void __cudaCheckError( const char *file, const int line )
{
#ifdef CUDA_ERROR_CHECK
    cudaError err = cudaGetLastError();
    if ( cudaSuccess != err )
    {
        fprintf( stderr, "cudaCheckError() failed at %s:%i : %s\n",
                 file, line, cudaGetErrorString( err ) );
        exit( -1 );
    }

    // More careful checking. However, this will affect performance.
    // Comment away if needed.
    err = cudaDeviceSynchronize();
    if( cudaSuccess != err )
    {
        fprintf( stderr, "cudaCheckError() with sync failed at %s:%i : %s\n",
                 file, line, cudaGetErrorString( err ) );
        exit( -1 );
    }
#endif

    return;
}



__constant__ static uint8_t __align__(8) c_phash[32];
__constant__ static uint8_t __align__(8) c_input32[108];
__constant__ static uint8_t __align__(8) c_difficulty;
__constant__ static int Z_PREP[4]  = {12,13,14,15};
__constant__ static int Y_PREP[2]  = {16,17};
__constant__ static int Z_ING[16]  = {18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33};
__constant__ static int Y_ING[8]   = {34,35,36,37,38,39,40,41};
__constant__ static int X_ING[2]   = {42,43};
__constant__ static int Z_INF[16]  = {44,45,46,47,48,50,51,52,53,54,55,56,57,58,59,60};
__constant__ static int Z_ADJ[64]  = {61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,
                                      81,82,83,84,85,86,87,88,89,90,91,92,94,95,96,97,98,99,100,
                                      101,102,103,104,105,107,108,109,110,112,114,115,116,117,118,
                                      119,120,121,122,123,124,125,126,127,128};
__constant__ static int Z_AMB[16]  = {77,94,95,96,126,214,217,218,220,222,223,224,225,226,227,228};
__constant__ static int Z_TIMED[8] = {84,243,249,250,251,252,253,255};
__constant__ static int Z_NS[64]   = {129,130,131,132,133,134,135,136,137,138,145,149,154,155,156,
                                      157,177,178,179,180,182,183,184,185,186,187,188,189,190,191,
                                      192,193,194,196,197,198,199,200,201,202,203,204,205,206,207,
                                      208,209,210,211,212,213,241,244,245,246,247,248,249,250,251,
                                      252,253,254,255};
__constant__ static int Z_NPL[32]  = {139,140,141,142,143,144,146,147,148,150,151,153,158,159,160,
                                      161,162,163,164,165,166,167,168,169,170,171,172,173,174,175,
                                      176,181};
__constant__ static int Z_MASS[16] = {214,215,216,217,218,219,220,221,222,223,224,225,226,227,228,229};
__constant__ static int Y_MASS[8]  = {230,231,232,233,234,235,236,237};
__constant__ static int X_MASS[4]  = {238,239,240,242};
__constant__ static int Z_INGINF[32] = {18,19,20,21,22,25,26,27,28,29,30,36,37,38,39,40,41,42,44,
                                        46,47,48,49,51,52,53,54,55,56,57,58,59};
__constant__ static int Z_TIME[16] = {82,83,84,85,86,87,88,243,249,250,251,252,253,254,255,253};
__constant__ static int Z_INGADJ[64] = {18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,
                                        37,38,39,40,41,42,43,23,24,31,32,33,34,61,62,63,64,65,66,
                                        67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,
                                        86,87,88,89,90,91,92};



__device__ uint32_t cuda_next_index(uint32_t tilenum, uint8_t *g_map, uint8_t *nonce) {
  /**
   * Assume tile[1024] pointer and nonce[16] pointer
   * Plus an additional unsigned - 0x20A0 bits */
   int i;
  uint32_t index;
  byte hash[HASHLEN];
  cuda_SHA256_CTX ictx;
   
  cuda_sha256_init(&ictx);
  cuda_sha256_update(&ictx, nonce, HASHLEN);
  cuda_sha256_update(&ictx, (byte *) &tilenum, sizeof(uint32_t));
  cuda_sha256_update(&ictx, &g_map[tilenum * TILE_LENGTH], TILE_LENGTH);

  cuda_sha256_final(&ictx, hash);
   
   /* Convert 32-byte Hash Value Into 32-bit Unsigned Integer */
   for(i = 0, index = 0; i < (HASHLEN / 4); i++) index += *((uint32_t *) &hash[i]);

  return index % MAP;
}

__device__ void cuda_gen_tile(uint32_t tilenum, uint8_t *phash, uint8_t *g_map) {
  /**
   * Declarations */
  cuda_SHA256_CTX ictx;
  int i, j, k, t, z;
  uint8_t bits, _104, _72, selector, *tilep;
  uint32_t op;
  float floatv, *floatp;
  
  _104 = 104;
  _72 = 72;

  /* set map pointer */
  tilep = &g_map[tilenum * TILE_LENGTH];
  
  /* begin tile data */
  cuda_sha256_init(&ictx);
  cuda_sha256_update(&ictx, phash, HASHLEN);
  cuda_sha256_update(&ictx, (byte*)&tilenum, sizeof(uint32_t));
  cuda_sha256_final(&ictx, tilep);

    for(i = j = k = 0; i < TILE_LENGTH; i+=HASHLEN) //for each row of the tile
    {
      for(op = 0; j < i + HASHLEN; j += 4)
      {
         /* set float pointer */
         floatp = (float *) &tilep[j];
        if(PEACH_DEBUG && j==0)
           printf("GPU tile[%u] output: %a ", tilenum, *floatp);
         
         /* Byte selections depend on initial 8 bits
          * Note: Trying not to perform "floatv =" first */
         switch(tilep[k] & 7) {
            case 0:
               // skip a byte
               k++;
               // determine floating point operation type
               op = tilep[k++];
               // determine which byte to select on the current 32 byte series
               selector = tilep[k++] & (HASHLEN - 1); // & (HASHLEN - 1), returns 0-31
               floatv = (float) tilep[i + selector]; // i + selector, index in 32 byte series
               // determine if floating point operation is performed on a negative number
               if(tilep[k++] & 1) floatv = (float)((int)floatv ^ 0x80000000);
               break;
            case 1:
               k++;
               selector = tilep[k++] & (HASHLEN - 1);
               floatv = (float) tilep[i + selector];
               if(tilep[k++] & 1) floatv = (float)((int)floatv ^ 0x80000000);
               op = tilep[k++];
               break;
            case 2:
               op = tilep[k++];
               k++;
               selector = tilep[k++] & (HASHLEN - 1);
               floatv = (float) tilep[i + selector];
               if(tilep[k++] & 1) floatv = (float)((int)floatv ^ 0x80000000);
               break;
            case 3:
               op = tilep[k++];
               selector = tilep[k++] & (HASHLEN - 1);
               floatv = (float) tilep[i + selector];
               if(tilep[k++] & 1) floatv = (float)((int)floatv ^ 0x80000000);
               k++;
               break;
            case 4:
               selector = tilep[k++] & (HASHLEN - 1);
               floatv = (float) tilep[i + selector];
               if(tilep[k++] & 1) floatv = (float)((int)floatv ^ 0x80000000);
               k++;
               op = tilep[k++];
               break;
            case 5:
               selector = tilep[k++] & (HASHLEN - 1);
               floatv = (float) tilep[i + selector];
               if(tilep[k++] & 1) floatv = (float)((int)floatv ^ 0x80000000);
               op = tilep[k++];
               k++;
               break;
            case 6:
               op = tilep[k++];
               selector = tilep[k++] & (HASHLEN - 1);
               floatv = (float) tilep[i + selector];
               k++;
               if(tilep[k++] & 1) floatv = (float)((int)floatv ^ 0x80000000);
               break;
            case 7:
               k++;
               selector = tilep[k++] & (HASHLEN - 1);
               floatv = (float) tilep[i + selector];
               op = tilep[k++];
               if(tilep[k++] & 1) floatv = (float)((int)floatv ^ 0x80000000);
               break;
         }

         /* Replace NaN's with tileNum. */
         if(isnan(*floatp)) *floatp = (float) tilenum;
         if(isnan(floatv)) floatv = (float) tilenum;

         /* Float operation depends on final 8 bits.
          * Perform floating point operation. */
         switch(op & 3) {
            case 0:
                  *floatp += floatv;
                  break;
            case 1:
                  *floatp -= floatv;
                  break;
            case 2:
                  *floatp *= floatv;
                  break;
            case 3:
                  *floatp /= floatv;
                  break;
         }
         
        if(PEACH_DEBUG && j==992)
           printf("%a | ", *floatp);
         
         
      } /* end for(op = 0... */
      
      /* Execute bit manipulations per tile row. */
      for(t = 0; t < TILE_TRANSFORMS; t++) {
         /* Determine tile byte offset and operation to use. */
         op += (uint32_t) tilep[i + (t % HASHLEN)];

         switch(op & 7) {
            case 0: /* Swap the first and last bit in each byte. */
               for(z = 0; z < HASHLEN; z++) tilep[i + z] ^= 0x81;
               break;
            case 1: /* Swap bytes */
               for(z = 0;z<HASHLENMID;z++) {
                  bits = tilep[i + z];
                  tilep[i + z] = tilep[i + HASHLENMID + z];
                  tilep[i + HASHLENMID + z] = bits;
               }
               break;
            case 2: /* Complement One, all bytes */
               for(z = 1; z < HASHLEN; z++) tilep[i + z] = ~tilep[i + z];
               break;
            case 3: /* Alternate +1 and -1 on all bytes */
               for(z = 0; z < HASHLEN; z++) {
                  tilep[i + z] += ((z & 1) == 0) ? 1 : -1;
               }
               break;
            case 4: /* Alternate +t and -t on all bytes */
               for(z = 0; z < HASHLEN; z++) {
                  tilep[i + z] += ((z & 1) == 0) ? -t : t;
               }
               break;
            case 5: /* Replace every occurrence of h with H */ 
               for(z = 0; z < HASHLEN; z++) {
                  if(tilep[i + z] == _104) tilep[i + z] = _72;
               }
               break;
            case 6: /* If byte a is > byte b, swap them. */
               for(z = 0; z < HASHLENMID; z++) {
                  if(tilep[i + z] > tilep[i + HASHLENMID + z]) {
                     bits = tilep[i + z];
                     tilep[i + z] = tilep[i + HASHLENMID + z];
                     tilep[i + HASHLENMID + z] = bits;
                  }
               }
               break;
            case 7: /* XOR all bytes */
               for(z = 1; z < HASHLEN; z++) tilep[i + z] ^= tilep[i + z - 1];
               break;
         } /* end switch(... */
      } /* end for(t = 0... */ 
      
      /* hash the result of the current tile's row to the next */
      if(j < TILE_LENGTH) {
        cuda_sha256_init(&ictx);
        cuda_sha256_update(&ictx, &tilep[i], HASHLEN);
        cuda_sha256_update(&ictx, (byte*)&tilenum, sizeof(uint32_t));
        cuda_sha256_final(&ictx, &tilep[j]);
      }
    }
}

__global__ void cuda_find_peach(uint32_t threads, uint8_t *g_map, uint8_t *g_cache, 
                           int *g_found, uint8_t *g_seed) {

  const uint32_t thread = blockDim.x * blockIdx.x + threadIdx.x;
  cuda_SHA256_CTX ictx;
  uint32_t sm;
  uint8_t bt_hash[32], fhash[32];
  uint8_t seed[16] = {0}, nonce[32] = {0};
  int i, j, n, x;

  
   if (thread <= threads) {
      /* Frame 1 -> Split 6 ways */
      if(thread < 32768) { /* Total Permutations, this frame: 32,768 ( 1 << 15 ) */
         seed[ 0] = Z_PREP[(thread & 3)];       // 2^2
         seed[ 1] = Z_TIMED[(thread >> 2) & 7]; // 2^3
         seed[ 2] = 1;
         seed[ 3] = 5;
         seed[ 4] = Z_NS[(thread >> 5) & 63];   // 2^6
         seed[ 5] = 1;
         seed[ 6] = Z_ING[(thread >> 11) & 15]; // 2^4
      } else
      if(thread < 49152) { /* Total Permutations, this frame: 16,384 ( 1 << 14 ) */
         seed[ 0] = Y_PREP[(thread & 1)];       // 2^1
         seed[ 1] = Z_TIMED[(thread >> 1) & 7]; // 2^3
         seed[ 2] = 1;
         seed[ 3] = 5;
         seed[ 4] = Z_NS[(thread >> 4) & 63];   // 2^6
         seed[ 5] = 1;
         seed[ 6] = Z_ING[(thread >> 10) & 15]; // 2^4
      } else
      if(thread < 65536) { /* Total Permutations, this frame: 16,384 ( 1 << 14 ) */
         seed[ 0] = Z_PREP[(thread & 3)];       // 2^2
         seed[ 1] = Z_TIMED[(thread >> 2) & 7]; // 2^3
         seed[ 2] = 1;
         seed[ 3] = 5;
         seed[ 4] = Z_NS[(thread >> 5) & 63];   // 2^6
         seed[ 5] = 1;
         seed[ 6] = Y_ING[(thread >> 11) & 7]; // 2^3
      } else
      if(thread < 73728) { /* Total Permutations, this frame: 8,192 ( 1 << 13 ) */
         seed[ 0] = Y_PREP[(thread & 1)];       // 2^1
         seed[ 1] = Z_TIMED[(thread >> 1) & 7]; // 2^3
         seed[ 2] = 1;
         seed[ 3] = 5;
         seed[ 4] = Z_NS[(thread >> 4) & 63];   // 2^6
         seed[ 5] = 1;
         seed[ 6] = Y_ING[(thread >> 10) & 7]; // 2^3
      } else
      if(thread < 81920) { /* Total Permutations, this frame: 16,384 ( 1 << 13 ) */
         seed[ 0] = Z_PREP[(thread & 3)];       // 2^2
         seed[ 1] = Z_TIMED[(thread >> 2) & 7]; // 2^3
         seed[ 2] = 1;
         seed[ 3] = 5;
         seed[ 4] = Z_NS[(thread >> 5) & 63];   // 2^6
         seed[ 5] = 1;
         seed[ 6] = X_ING[(thread >> 11) & 3]; // 2^2
      } else
      if(thread < 86016) { /* Total Permutations, this frame: 8,192 ( 1 << 12 ) */
         seed[ 0] = Y_PREP[(thread & 1)];       // 2^1
         seed[ 1] = Z_TIMED[(thread >> 1) & 7]; // 2^3
         seed[ 2] = 1;
         seed[ 3] = 5;
         seed[ 4] = Z_NS[(thread >> 4) & 63];   // 2^6
         seed[ 5] = 1;
         seed[ 6] = X_ING[(thread >> 10) & 3];  // 2^2
      } else
      /* END Frame 1 */
      /* Frame 2 -> Split 3 ways */
      if(thread <= 151552) { /* Total Permutations, this frame: 65,536 (1 << 16) */
         seed[ 0] = Z_TIME[(thread & 15)];      // 2^4
         seed[ 1] = Y_MASS[(thread >> 4) & 15]; // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_INF[(thread >> 8) & 15];  // 2^4
         seed[ 4] = 9;
         seed[ 5] = 2;
         seed[ 6] = 1;
         seed[ 7] = Z_AMB[(thread >> 12) & 15]; // 2^4
      } else
      if(thread <= 184320) { /* Total Permutations, this frame: 32,768 (1 << 15) */
         seed[ 0] = Z_TIME[(thread & 15)];      // 2^4
         seed[ 1] = X_MASS[(thread >> 3) & 7];  // 2^3
         seed[ 2] = 1;
         seed[ 3] = Z_INF[(thread >> 7) & 15];  // 2^4
         seed[ 4] = 9;
         seed[ 5] = 2;
         seed[ 6] = 1;
         seed[ 7] = Z_AMB[(thread >> 11) & 15]; // 2^4
      } else
      if(thread <= 200704) { /* Total Permutations, this frame: 16,384 (1 << 14) */
         seed[ 0] = Z_TIME[(thread & 15)];      // 2^4
         seed[ 1] = Z_MASS[(thread >> 2) & 3];  // 2^2
         seed[ 2] = 1;
         seed[ 3] = Z_INF[(thread >> 6) & 15];  // 2^4
         seed[ 4] = 9;
         seed[ 5] = 2;
         seed[ 6] = 1;
         seed[ 7] = Z_AMB[(thread >> 10) & 15]; // 2^4
      } else
      /* END Frame 2 */
      /* Frame 3 -> Split 2 ways */
      if(thread < 2297856) { /* Total Permutations, this frame: 2,097,152 ( 1 << 21 )*/
         seed[ 0] = Z_PREP[(thread & 3)];          // 2^2
         seed[ 1] = Z_TIMED[(thread >> 2) & 7];    // 2^3
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 5) & 63];     // 2^6
         seed[ 4] = Z_NPL[(thread >> 11) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 16) & 31]; // 2^5
      } else
      if(thread < 3346432) { /* Total Permutations, this frame: 1,048,576 ( 1 << 20 )*/
         seed[ 0] = Y_PREP[(thread & 1)];          // 2^1
         seed[ 1] = Z_TIMED[(thread >> 1) & 7];    // 2^3
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 4) & 63];     // 2^6
         seed[ 4] = Z_NPL[(thread >> 10) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 15) & 31]; // 2^5
      } else
      /* END Frame 3 */
      /* Frame 4 -> Split 6 ways */
      if(thread < 5443584) { /* Total Permutations, this frame: 2,097,152 ( 1 << 21 ) */
         seed[ 0] = 5;
         seed[ 1] = Z_NS[(thread & 63)];           // 2^6
         seed[ 2] = 1;
         seed[ 3] = Z_PREP[(thread >> 6) & 3];     // 2^2
         seed[ 4] = Z_TIMED[(thread >> 8) & 7];    // 2^3
         seed[ 5] = Z_MASS[(thread >> 11) & 15];   // 2^4
         seed[ 6] = 3;
         seed[ 7] = 1;
         seed[ 8] = Z_ADJ[(thread >> 15) & 63];    // 2^6
      } else
      if(thread < 6492160) { /* Total Permutations, this frame: 1,048,576 ( 1 << 20 ) */
         seed[ 0] = 5;
         seed[ 1] = Z_NS[(thread & 63)];           // 2^6
         seed[ 2] = 1;
         seed[ 3] = Y_PREP[(thread >> 6) & 1];     // 2^1
         seed[ 4] = Z_TIMED[(thread >> 7) & 7];    // 2^3
         seed[ 5] = Z_MASS[(thread >> 10) & 15];   // 2^4
         seed[ 6] = 3;
         seed[ 7] = 1;
         seed[ 8] = Z_ADJ[(thread >> 14) & 63];    // 2^6
      } else
      if(thread < 7540736) { /* Total Permutations, this frame: 1,048,576 ( 1 << 20 ) */
         seed[ 0] = 5;
         seed[ 1] = Z_NS[(thread & 63)];           // 2^6
         seed[ 2] = 1;
         seed[ 3] = Z_PREP[(thread >> 6) & 3];     // 2^2
         seed[ 4] = Z_TIMED[(thread >> 8) & 7];    // 2^3
         seed[ 5] = Y_MASS[(thread >> 11) & 7];    // 2^3
         seed[ 6] = 3;
         seed[ 7] = 1;
         seed[ 8] = Z_ADJ[(thread >> 14) & 63];    // 2^6
      } else
      if(thread < 8065024) { /* Total Permutations, this frame: 524,288 ( 1 << 19 ) */
         seed[ 0] = 5;
         seed[ 1] = Z_NS[(thread & 63)];           // 2^6
         seed[ 2] = 1;
         seed[ 3] = Y_PREP[(thread >> 6) & 1];     // 2^1
         seed[ 4] = Z_TIMED[(thread >> 7) & 7];    // 2^3
         seed[ 5] = Y_MASS[(thread >> 10) & 7];    // 2^3
         seed[ 6] = 3;
         seed[ 7] = 1;
         seed[ 8] = Z_ADJ[(thread >> 13) & 63];    // 2^6
      } else
      if(thread < 8589312) { /* Total Permutations, this frame: 524,288 ( 1 << 19 ) */
         seed[ 0] = 5;
         seed[ 1] = Z_NS[(thread & 63)];           // 2^6
         seed[ 2] = 1;
         seed[ 3] = Z_PREP[(thread >> 6) & 3];     // 2^2
         seed[ 4] = Z_TIMED[(thread >> 8) & 7];    // 2^3
         seed[ 5] = X_MASS[(thread >> 11) & 3];    // 2^2
         seed[ 6] = 3;
         seed[ 7] = 1;
         seed[ 8] = Z_ADJ[(thread >> 13) & 63];    // 2^6
      } else
      if(thread < 8851456) { /* Total Permutations, this frame: 262,144 ( 1 << 18 ) */
         seed[ 0] = 5;
         seed[ 1] = Z_NS[(thread & 63)];           // 2^6
         seed[ 2] = 1;
         seed[ 3] = Y_PREP[(thread >> 6) & 1];     // 2^1
         seed[ 4] = Z_TIMED[(thread >> 7) & 7];    // 2^3
         seed[ 5] = X_MASS[(thread >> 10) & 3];    // 2^2
         seed[ 6] = 3;
         seed[ 7] = 1;
         seed[ 8] = Z_ADJ[(thread >> 12) & 63];    // 2^6
      } else
      /* END Frame 4 */
      /* Frame 5 -> Split 6 ways */
      if(thread < 13045760) { /* Total Permutations, this frame: 4,194,304 ( 1 << 22 ) */
         seed[ 0] = Z_PREP[thread & 3];            // 2^2
         seed[ 1] = Z_ADJ[(thread >> 2) & 63];     // 2^6
         seed[ 2] = Z_MASS[(thread >> 8) & 15];    // 2^4
         seed[ 3] = 1;
         seed[ 4] = Z_NPL[(thread >> 12) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 17) & 31]; // 2^5
      } else
      if(thread < 15142912) { /* Total Permutations, this frame: 2,097,152 ( 1 << 21 ) */
         seed[ 0] = Y_PREP[thread & 1];            // 2^1
         seed[ 1] = Z_ADJ[(thread >> 1) & 63];     // 2^6
         seed[ 2] = Z_MASS[(thread >> 7) & 15];    // 2^4
         seed[ 3] = 1;
         seed[ 4] = Z_NPL[(thread >> 11) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 16) & 31]; // 2^5
      } else
      if(thread < 17240064) { /* Total Permutations, this frame: 2,097,152 ( 1 << 21 ) */
         seed[ 0] = Z_PREP[thread & 3];            // 2^2
         seed[ 1] = Z_ADJ[(thread >> 2) & 63];     // 2^6
         seed[ 2] = Y_MASS[(thread >> 8) & 7];     // 2^3
         seed[ 3] = 1;
         seed[ 4] = Z_NPL[(thread >> 11) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 16) & 31]; // 2^5
      } else
      if(thread < 18288640) { /* Total Permutations, this frame: 1,048,576 ( 1 << 20 ) */
         seed[ 0] = Y_PREP[thread & 1];            // 2^1
         seed[ 1] = Z_ADJ[(thread >> 1) & 63];     // 2^6
         seed[ 2] = Y_MASS[(thread >> 7) & 7];     // 2^3
         seed[ 3] = 1;
         seed[ 4] = Z_NPL[(thread >> 10) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 15) & 31]; // 2^5
      } else
      if(thread < 19337216) { /* Total Permutations, this frame: 1,048,576 ( 1 << 20 ) */
         seed[ 0] = Z_PREP[thread & 3];            // 2^2
         seed[ 1] = Z_ADJ[(thread >> 2) & 63];     // 2^6
         seed[ 2] = X_MASS[(thread >> 8) & 3];     // 2^2
         seed[ 3] = 1;
         seed[ 4] = Z_NPL[(thread >> 10) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 15) & 31]; // 2^5
      } else
      if(thread < 19861504) { /* Total Permutations, this frame: 524,288 ( 1 << 19 ) */
         seed[ 0] = Y_PREP[thread & 1];            // 2^1
         seed[ 1] = Z_ADJ[(thread >> 1) & 63];     // 2^6
         seed[ 2] = X_MASS[(thread >> 7) & 3];     // 2^2
         seed[ 3] = 1;
         seed[ 4] = Z_NPL[(thread >> 9) & 31];     // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 14) & 31]; // 2^5
      } else
      /* END Frame 5 */
      /* Frame 6 -> Split 6 ways */
      if(thread < 24055808) { /* Total Permutations, this frame: 4,194,304 ( 1 << 22 ) */
         seed[ 0] = Z_PREP[(thread & 3)];          // 2^2
         seed[ 1] = Z_MASS[(thread >> 2) & 15];    // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 6) & 63];     // 2^6
         seed[ 4] = Z_NPL[(thread >> 12) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 17) & 31]; // 2^5
      } else
      if(thread < 26152960) { /* Total Permutations, this frame: 2,097,152 ( 1 << 21 ) */
         seed[ 0] = Y_PREP[(thread & 1)];          // 2^1
         seed[ 1] = Z_MASS[(thread >> 1) & 15];    // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 5) & 63];     // 2^6
         seed[ 4] = Z_NPL[(thread >> 11) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 16) & 31]; // 2^5
      } else
      if(thread < 28250112) { /* Total Permutations, this frame: 2,097,152 ( 1 << 21 ) */
         seed[ 0] = Z_PREP[(thread & 3)];          // 2^2
         seed[ 1] = Y_MASS[(thread >> 2) & 7];     // 2^3
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 5) & 63];     // 2^6
         seed[ 4] = Z_NPL[(thread >> 11) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 16) & 31]; // 2^5
      } else
      if(thread < 29298688) { /* Total Permutations, this frame: 1,048,576 ( 1 << 20 ) */
         seed[ 0] = Y_PREP[(thread & 1)];          // 2^1
         seed[ 1] = Y_MASS[(thread >> 1) & 7];     // 2^3
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 4) & 63];     // 2^6
         seed[ 4] = Z_NPL[(thread >> 10) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 15) & 31]; // 2^5
      } else
      if(thread < 30347264) { /* Total Permutations, this frame: 1,048,576 ( 1 << 20 ) */
         seed[ 0] = Z_PREP[(thread & 3)];          // 2^2
         seed[ 1] = X_MASS[(thread >> 2) & 3];     // 2^2
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 5) & 63];     // 2^6
         seed[ 4] = Z_NPL[(thread >> 11) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 16) & 31]; // 2^5
      } else
      if(thread < 30871552) { /* Total Permutations, this frame: 524,288 ( 1 << 19 ) */
         seed[ 0] = Y_PREP[(thread & 1)];          // 2^1
         seed[ 1] = X_MASS[(thread >> 1) & 3];     // 2^2
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 4) & 63];     // 2^6
         seed[ 4] = Z_NPL[(thread >> 10) & 31];    // 2^5
         seed[ 5] = 1;
         seed[ 6] = Z_INGINF[(thread >> 15) & 31]; // 2^5
      } else
      /* END Frame 6 */
      /* Frame 7 -> Split 9 ways */
      if(thread < 35065856) { /* Total Permutations, this frame: 4,194,304 ( 1 << 22 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 8) & 63];     // 2^6
         seed[ 4] = Z_MASS[(thread >> 14) & 15];   // 2^4
         seed[ 5] = 1;
         seed[ 6] = Z_ING[(thread >> 18) & 15];    // 2^4
      } else
      if(thread < 37163088) { /* Total Permutations, this frame: 2,097,152 ( 1 << 21 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 8) & 63];     // 2^6
         seed[ 4] = Y_MASS[(thread >> 14) & 7];    // 2^3
         seed[ 5] = 1;
         seed[ 6] = Z_ING[(thread >> 17) & 15];    // 2^4
      } else
      if(thread < 38211584) { /* Total Permutations, this frame: 1,048,576 ( 1 << 20 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 8) & 63];     // 2^6
         seed[ 4] = X_MASS[(thread >> 14) & 3];    // 2^2
         seed[ 5] = 1;
         seed[ 6] = Z_ING[(thread >> 16) & 15];    // 2^4
      } else
      if(thread < 40308736) { /* Total Permutations, this frame: 2,097,152 ( 1 << 21 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 8) & 63];     // 2^6
         seed[ 4] = Z_MASS[(thread >> 14) & 15];   // 2^4
         seed[ 5] = 1;
         seed[ 6] = Y_ING[(thread >> 18) & 7];     // 2^3
      } else
      if(thread < 41357312) { /* Total Permutations, this frame: 1,048,576 ( 1 << 20 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 8) & 63];     // 2^6
         seed[ 4] = Y_MASS[(thread >> 14) & 7];    // 2^3
         seed[ 5] = 1;
         seed[ 6] = Y_ING[(thread >> 17) & 7];     // 2^3
      } else
      if(thread < 41881600) { /* Total Permutations, this frame: 524,288 ( 1 << 19 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 8) & 63];     // 2^6
         seed[ 4] = X_MASS[(thread >> 14) & 3];    // 2^2
         seed[ 5] = 1;
         seed[ 6] = Y_ING[(thread >> 16) & 7];     // 2^3
      } else
      if(thread < 42405888) { /* Total Permutations, this frame: 524,288 ( 1 << 19  ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 8) & 63];     // 2^6
         seed[ 4] = Z_MASS[(thread >> 14) & 15];   // 2^4
         seed[ 5] = 1;
         seed[ 6] = X_ING[(thread >> 18) & 1];     // 2^1
      } else
      if(thread < 42668032) { /* Total Permutations, this frame: 262,144 ( 1 << 18 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 8) & 63];     // 2^6
         seed[ 4] = Y_MASS[(thread >> 14) & 7];    // 2^3
         seed[ 5] = 1;
         seed[ 6] = X_ING[(thread >> 17) & 1];     // 2^1
      } else
      if(thread < 42799104) { /* Total Permutations, this frame: 131,072 ( 1 << 17 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_ADJ[(thread >> 8) & 63];     // 2^6
         seed[ 4] = X_MASS[(thread >> 14) & 3];    // 2^2
         seed[ 5] = 1;
         seed[ 6] = X_ING[(thread >> 16) & 1];     // 2^1
      } else
      /* END Frame 7 */
      /* Frame 8 -> Split 2 ways */
      if(thread < 311234560) { /* Total Permutations, this frame: 268,435,456 ( 1 << 28 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Z_PREP[(thread >> 8) & 3];     // 2^2
         seed[ 4] = 5;
         seed[ 5] = Z_ADJ[(thread >> 10) & 63];    // 2^6
         seed[ 6] = Z_NS[(thread >> 16) & 63];     // 2^6
         seed[ 7] = 3;
         seed[ 8] = 1;
         seed[ 9] = Z_INGADJ[(thread >> 22) & 63]; // 2^6
      } else
      if(thread < 445452288) { /* Total Permutations, this frame: 134,217,728 ( 1 << 27 ) */
         seed[ 0] = Z_TIME[(thread & 15)];         // 2^4
         seed[ 1] = Z_AMB[(thread >> 4) & 15];     // 2^4
         seed[ 2] = 1;
         seed[ 3] = Y_PREP[(thread >> 8) & 1];     // 2^1
         seed[ 4] = 5;
         seed[ 5] = Z_ADJ[(thread >> 9) & 63];     // 2^6
         seed[ 6] = Z_NS[(thread >> 15) & 63];     // 2^6
         seed[ 7] = 3;
         seed[ 8] = 1;
         seed[ 9] = Z_INGADJ[(thread >> 21) & 63]; // 2^6
      }

/* Below Two Frames are Valid, But Require 64-Bit Math: if extra entropy req'd.
   if( < thread <= ) { /* Total Permutations, this frame: 549,755,813,888
	seed[ 0] = Z_ING[(thread & 31)]; 
	seed[ 1] = Z_PREP[(thread << 5) & 7];
	seed[ 2] = Z_TIME[(thread << 8) & 15]; 
	seed[ 3] = Z_MASS[(thread << 12) & 31]; 
	seed[ 4] = 1;
        seed[ 5] = Z_MASS[(thread << 17) & 31]; 
	seed[ 6] = Z_ING[(thread << 22) & 31];  
	seed[ 7] = 3; 
	seed[ 8] = 1;
        seed[ 9] = 5; 
	seed[10] = Z_ADJ[(thread << 27) & 63];
	seed[11] = Z_NS[(thread << 33) & 63];
   }
   if( < thread <= ) { /* Total Permutations, this frame: 4,398,046,511,104
	seed[ 0] = Z_ING[(thread & 31)]; 
	seed[ 1] = Z_PREP[(thread << 5) & 7]; 
	seed[ 2] = 5; 
	seed[ 3] = Z_ADJ[(thread << 8) & 63]; 
	seed[ 4] = Z_NS[(thread << 14) & 63]; 
	seed[ 5] = 1;
        seed[ 6] = Z_MASS[(thread << 19) & 31]; 
	seed[ 7] = Z_ING[(thread << 24) & 31];  
	seed[ 8] = 3; 
	seed[ 9] = 1;
        seed[10] = 5; 
	seed[11] = Z_ADJ[(thread << 30) & 63]; 
	seed[12] = Z_NS[(thread << 36) & 63];
   }
End 64-bit Frames */
     
     /* store full nonce */
     #pragma unroll
     for (i = 0; i < 16; i++)
       nonce[i] = c_input32[i + 92];
     
     #pragma unroll
     for (i = 0; i < 16; i++)
       nonce[i+16] = seed[i];
     
     /*********************************************************/
     /* Hash 124 bytes of Block Trailer, including both seeds */
     /* Get the wizard to draw you a map to the princess!     */
       
       
     cuda_sha256_init(&ictx);

     /* update sha with the available block trailer data */
     cuda_sha256_update(&ictx, c_input32, 108);
     
     /* update sha with the second seed (16 bytes) */
     cuda_sha256_update(&ictx, seed, 16);
     
     /* finalise sha256 hash */
     cuda_sha256_final(&ictx, bt_hash);
     
     
     /*****************************************************/
     /* Determine the final tile based on selected nonce  */
     /* Follow the wizard's map to find the princess!     */
     
     /* determine first tile index */
     sm = bt_hash[0];
     for(i = 1; i < HASHLEN; i++)
       sm *= bt_hash[i];
     
     sm %= MAP;

     /* get cached tile, or generate one if it doesn't exist */
     //if(!g_cache[sm]) {
          cuda_gen_tile(sm, c_phash, g_map);
          g_cache[sm] = 1;
      // }
     
     /* make <JUMP> tile jumps to find the final tile */
     for(j = 0; j < JUMP; j++) {
       /* determine next tile index */
       sm = cuda_next_index(sm, g_map, nonce);
       
       /* get cached tile, or generate one if it doesn't exist */
      // if(!g_cache[sm]) {
          cuda_gen_tile(sm, c_phash, g_map);
          g_cache[sm] = 1;
      // }
     }

     /****************************************************************/
     /* Check the hash of the final tile produces the desired result */
     /* Search the castle for the princess!                          */
      
     cuda_sha256_init(&ictx);
     cuda_sha256_update(&ictx, bt_hash, HASHLEN);
     cuda_sha256_update(&ictx, &g_map[sm * TILE_LENGTH], TILE_LENGTH);
     cuda_sha256_final(&ictx, fhash);
     
     
     /* evaluate hash */
     for (x = i = j = n = 0; i < HASHLEN; i++) {
       x = fhash[i];
       if (x != 0) {
         for(j = 7; j > 0; j--) {
           x >>= 1;
           if(x == 0) {
             n += j;
             break;
           }
         }
         break;
       }
       n += 8;
     }
     if(n >= c_difficulty) {
       /* PRINCESS FOUND! */
       *g_found = 1;
       #pragma unroll
       for (i = 0; i < 16; i++)
         g_seed[i] = seed[i];
        
      if(PEACH_DEBUG) {
         printf("GPU BT HASH output: ");
         for(i = 0; i < 32; i++) 
           printf(" %02X", bt_hash[i]);
         printf("\n");
         printf("GPU FINAL HASH output: ");
         for(i = 0; i < 32; i++) 
           printf(" %02X", fhash[i]);
         printf("\n");
      }
     }
     
      /* Our princess is in another castle ! */
     
   }
}



extern "C" {

typedef struct __peach_cuda_ctx {
    byte curr_seed[16], next_seed[16];
    int *d_found;
    uint8_t *seed, *d_seed, *d_cache;
    uint8_t *input, *d_map;
    cudaStream_t stream;
} PeachCudaCTX;

PeachCudaCTX ctx[63];    /* Max 63 GPUs Supported */
uint32_t threads = 1;
dim3 grid(1);
dim3 block(1);
char haikuGPU[256];
int *found;
byte *diff;
byte *phash;
byte bnum[8] = {0};
byte initGPU = 0;
int nGPU = 0;

int init_cuda_peach(byte difficulty, byte *prevhash, byte *blocknumber) {
    /* Obtain and check system GPU count */
    cudaGetDeviceCount(&nGPU);
    if(nGPU<1 || nGPU>63) return nGPU;
    /* Allocate pinned host memory */
    cudaMallocHost(&diff, 1);
    cudaMallocHost(&found, 4);
    cudaMallocHost(&phash, 32);
    cudaMallocHost(&found, 4);
    /* Copy immediate block data to pinned memory */
    memcpy(diff, &difficulty, 1);
    memset(found, 0, 4);
    memcpy(phash, prevhash, 32);

    int i = 0;
    for ( ; i<nGPU; i++) {
        cudaSetDevice(i);
        /* Create Stream */
        cudaStreamCreate(&ctx[i].stream);
        /* Allocate device memory */
        cudaMalloc(&ctx[i].d_found, 4);
        cudaMalloc(&ctx[i].d_seed, 16);
        /* Allocate associated device-host memory */
        cudaMallocHost(&ctx[i].seed, 16);
        cudaMallocHost(&ctx[i].input, 108);
        /* Copy immediate block data to device memory */
        cudaMemcpyToSymbolAsync(c_difficulty, diff, 1, 0,
                                cudaMemcpyHostToDevice, ctx[i].stream);
        cudaMemcpyToSymbolAsync(c_phash, phash, 32, 0,
                                cudaMemcpyHostToDevice, ctx[i].stream);
        /* Set remaining device memory */
        cudaMemsetAsync(ctx[i].d_found, 0, 4, ctx[i].stream);
        cudaMemsetAsync(ctx[i].d_seed, 0, 16, ctx[i].stream);
        /* Set initial round variables */
        ctx[i].next_seed[0] = 0;
        /* If first init, setup map and cache */
        if(initGPU == 0) {
            cudaMalloc(&ctx[i].d_map, MAP_LENGTH);
            cudaMalloc(&ctx[i].d_cache, MAP);
            initGPU = 1;
        }
        /* Wipe cache if new block */
        cudaMemsetAsync(ctx[i].d_cache, 0, MAP, ctx[i].stream);
    }

    return nGPU;
}

void free_cuda_peach() {
    /* Free pinned host memory */
    cudaFreeHost(diff);
    cudaFreeHost(found);
    cudaFreeHost(phash);

    int i = 0;
    for ( ; i<nGPU; i++) {
        cudaSetDevice(i);
        /* Destroy Stream */
        cudaStreamDestroy(ctx[i].stream);
        /* Free device memory */
        cudaFree(ctx[i].d_found);
        cudaFree(ctx[i].d_seed);
        /* Free associated device-host memory */
        cudaFreeHost(ctx[i].seed);
        cudaFreeHost(ctx[i].input);
    }
}

extern byte *trigg_gen(byte *in);
extern char *trigg_expand2(byte *in, byte *out);

__host__ char *cuda_peach(byte *bt, char *haiku, uint32_t *hps, byte *runflag)
{
    int i;
    uint64_t nHaiku;
    time_t seconds = time(NULL);
    for( ; *runflag && *found == 0; ) {
        for (i=0; i<nGPU; i++) {
            /* Prepare next seed for GPU... */
            if(ctx[i].next_seed[0] == 0) {
                /* ... generate first GPU seed (and expand as Haiku) */
                trigg_gen(ctx[i].next_seed);

                /* ... and prepare round data */
                memcpy(ctx[i].input, bt, 92);
                memcpy(ctx[i].input+92, ctx[i].next_seed, 16);
            }
            /* Check if GPU has finished */
            CudaCheckError();
            cudaSetDevice(i);
            if(cudaStreamQuery(ctx[i].stream) == cudaSuccess) {
                cudaMemcpy(found, ctx[i].d_found, 4, cudaMemcpyDeviceToHost);
                if(*found==1) { /* SOLVED A BLOCK! */
                    cudaMemcpy(ctx[i].seed, ctx[i].d_seed, 16, cudaMemcpyDeviceToHost);
                    memcpy(bt + 92, ctx[i].curr_seed, 16);
                    memcpy(bt + 92 + 16, ctx[i].seed, 16);
                    haiku = haikuGPU;
                    break;
                }
                /* Send new GPU round Data */
                cudaMemcpyToSymbolAsync(c_input32, ctx[i].input, 108, 0,
                                        cudaMemcpyHostToDevice, ctx[i].stream);
                /* Start GPU round */
                cuda_find_peach<<<grid, block, 0, ctx[i].stream>>>(threads,
                ctx[i].d_map, ctx[i].d_cache, ctx[i].d_found, ctx[i].d_seed);

                /* Add to haiku count */
                nHaiku += threads;

                /* Store round vars aside for checks next loop */
                memcpy(ctx[i].curr_seed,ctx[i].next_seed,16);
                ctx[i].next_seed[0] = 0;
            } else continue;  /* Waiting on GPU ... */
        }
    }
    
    seconds = time(NULL) - seconds;
    if(seconds == 0) seconds = 1;
    nHaiku /= seconds;
    *hps = (uint32_t) nHaiku;
         
    return haiku;
}


}
