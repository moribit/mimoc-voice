#include <AudioToolbox/AudioToolbox.h>
#include <stdatomic.h>
#include <stdlib.h>
typedef size_t (*Pull)(void *, short *, size_t);
typedef struct { AudioQueueRef queue; Pull pull; void *context; _Atomic int done; unsigned active; } Player;
static void fill(void *ctx, AudioQueueRef queue, AudioQueueBufferRef buffer) {
 Player *p=ctx; size_t n=p->pull(p->context,buffer->mAudioData,buffer->mAudioDataBytesCapacity/2);
 if(n) { buffer->mAudioDataByteSize=(UInt32)n*2; if(AudioQueueEnqueueBuffer(queue,buffer,0,NULL)!=noErr) atomic_store(&p->done,1); }
 else if(p->active && --p->active==0) { atomic_store(&p->done,1); AudioQueueStop(queue,false); }
}
void *voice_audio_start(void *ctx, Pull pull, unsigned rate) {
 Player *p=calloc(1,sizeof(*p)); if(!p)return NULL;p->pull=pull;p->context=ctx;
 AudioStreamBasicDescription fmt={0}; fmt.mSampleRate=rate;fmt.mFormatID=kAudioFormatLinearPCM;fmt.mFormatFlags=kLinearPCMFormatFlagIsSignedInteger|kLinearPCMFormatFlagIsPacked;fmt.mBytesPerPacket=2;fmt.mFramesPerPacket=1;fmt.mBytesPerFrame=2;fmt.mChannelsPerFrame=1;fmt.mBitsPerChannel=16;
 if(AudioQueueNewOutput(&fmt,fill,p,NULL,NULL,0,&p->queue)!=noErr){free(p);return NULL;}
 for(unsigned i=0;i<3;i++){AudioQueueBufferRef b;if(AudioQueueAllocateBuffer(p->queue,1024,&b)!=noErr)goto fail;size_t n=pull(ctx,b->mAudioData,512);if(!n)break;b->mAudioDataByteSize=(UInt32)n*2;if(AudioQueueEnqueueBuffer(p->queue,b,0,NULL)!=noErr)goto fail;p->active++;}
 if(!p->active){atomic_store(&p->done,1);return p;}
 if(AudioQueueStart(p->queue,NULL)!=noErr)goto fail;return p;
 fail:AudioQueueDispose(p->queue,true);free(p);return NULL;
}
int voice_audio_done(void *p){return atomic_load(&((Player*)p)->done);}
void voice_audio_stop(void *p){if(p){AudioQueueDispose(((Player*)p)->queue,true);free(p);}}
