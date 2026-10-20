// Exercise the compiled runtime-selected SIMD coupling, including its tail.
#include <stdio.h>
#include "libavcodec/vorbisdsp.h"
int main(void) {
  VorbisDSPContext dsp; ff_vorbisdsp_init(&dsp);
  const float magnitudes[] = {0.f, 0.f, -0.f, -0.f, 1.f, 1.f, -1.f, -1.f};
  const float angles[] = {2.f, -2.f, 2.f, -2.f, 2.f, -2.f, 2.f, -2.f};
  const float expected_m[] = {0.f, 2.f, 0.f, 2.f, 1.f, -1.f, -1.f, 1.f};
  const float expected_a[] = {2.f, 0.f, 2.f, 0.f, -1.f, 1.f, 1.f, -1.f};
  int failures=0, checks=0;
  for (int size=4;size<=32;size+=4) {
    float m[32], a[32];
    for(int i=0;i<size;i++){m[i]=magnitudes[i%8];a[i]=angles[i%8];}
    dsp.vorbis_inverse_coupling(m,a,size);
    for(int i=0;i<size;i++) {
      checks++;
      if(m[i]!=expected_m[i%8]||a[i]!=expected_a[i%8]) {
        fprintf(stderr,"coupling size=%d index=%d: got (%g,%g), expected (%g,%g)\n",
          size,i,m[i],a[i],expected_m[i%8],expected_a[i%8]); failures++;
      }
    }
  }
  printf("Vorbis coupling: %d vectors, %d failures\n",checks,failures);
  return failures?1:0;
}
