
#include "kwt_nice.h"
int main(void){
 volatile uint32_t *const ga=(volatile uint32_t*)0x10012000u;
 volatile uint32_t *const gb=(volatile uint32_t*)0x10040000u;
 volatile uint32_t *const m=(volatile uint32_t*)0xa0000000u;
 ga[0]=0;ga[7]=0;gb[7]=0;gb[2]=0;
 m[0]=0;m[0xfffc/4]=0;kwt_fence();gb[0]=1;
 for(volatile uint32_t wait=0;wait<16;wait++)__asm__ volatile("nop");
 uint32_t ack=0;
 {uint32_t i=0;for(;i+8u<=KWT_P_WORDS;i+=8){{uint32_t value=ga[1];m[0x10000/4+i+0]=value;ack^=1;gb[2]=ack;}
{uint32_t value=ga[1];m[0x10000/4+i+1]=value;ack^=1;gb[2]=ack;}
{uint32_t value=ga[1];m[0x10000/4+i+2]=value;ack^=1;gb[2]=ack;}
{uint32_t value=ga[1];m[0x10000/4+i+3]=value;ack^=1;gb[2]=ack;}
{uint32_t value=ga[1];m[0x10000/4+i+4]=value;ack^=1;gb[2]=ack;}
{uint32_t value=ga[1];m[0x10000/4+i+5]=value;ack^=1;gb[2]=ack;}
{uint32_t value=ga[1];m[0x10000/4+i+6]=value;ack^=1;gb[2]=ack;}
{uint32_t value=ga[1];m[0x10000/4+i+7]=value;ack^=1;gb[2]=ack;}}for(;i<KWT_P_WORDS;i++){uint32_t value=ga[1];m[0x10000/4+i]=value;ack^=1;gb[2]=ack;}}
 {uint32_t i=0;for(;i+8u<=KWT_X_WORDS;i+=8){{uint32_t value=ga[1];m[1+i+0]=value;ack^=1;gb[2]=ack;}
{uint32_t value=ga[1];m[1+i+1]=value;ack^=1;gb[2]=ack;}
{uint32_t value=ga[1];m[1+i+2]=value;ack^=1;gb[2]=ack;}
{uint32_t value=ga[1];m[1+i+3]=value;ack^=1;gb[2]=ack;}
{uint32_t value=ga[1];m[1+i+4]=value;ack^=1;gb[2]=ack;}
{uint32_t value=ga[1];m[1+i+5]=value;ack^=1;gb[2]=ack;}
{uint32_t value=ga[1];m[1+i+6]=value;ack^=1;gb[2]=ack;}
{uint32_t value=ga[1];m[1+i+7]=value;ack^=1;gb[2]=ack;}}for(;i<KWT_X_WORDS;i++){uint32_t value=ga[1];m[1+i]=value;ack^=1;gb[2]=ack;}}
 kwt_fence();m[0]=KWT_X_WORDS;m[0xfffc/4]=KWT_P_WORDS;kwt_fence();
 int r=kwt_ffn1((const int16_t*)0xa0000004u,(const uint32_t*)0xa0010000u,(int16_t*)0xa0020000u);
 m[0xff00/4]=r?(uint32_t)r:0x600d;return r?1:0;
}
