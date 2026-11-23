#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "camera.hpp"
#include <cstdio>
#include <mutex>
#include <memory>
namespace motion {
namespace {
const char* shader =
#include "shutter_kernels.inc"
;
struct Geometry {
    int width,height,grid,fieldWidth,fieldHeight,levels;
    int widths[7],heights[7],offsets[7];
    int hasPrev,hasNext,curve,samples;
    float exposure; int fusionCount, cinema;
};
// Keep at most one idle render of buffers. Concurrent renders own different scratch storage.
struct Scratch {
    id<MTLBuffer> slots[10]{};
    int width=0,height=0;
};
struct Engine {
    std::mutex cacheMutex;
    std::unique_ptr<Scratch> idle;
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue=[device newCommandQueue];
    id<MTLComputePipelineState> kernels[5];
    Engine(){
        NSError* error=nil;
        MTLCompileOptions* options=[MTLCompileOptions new];options.fastMathEnabled=NO;
        id<MTLLibrary> lib=[device newLibraryWithSource:[NSString stringWithUTF8String:shader] options:options error:&error];
        NSArray<NSString*>* names=@[@"luma",@"reducePlane",@"flow",@"integrateFrame",@"linearize"];
        for(int i=0;lib && i<5;++i){
            kernels[i]=[device newComputePipelineStateWithFunction:[lib newFunctionWithName:names[i]] error:&error];
            if(!kernels[i])break;
        }
        if(error)std::fprintf(stderr,"[Mecena Metal] %s\n",error.localizedDescription.UTF8String);
    }
    id<MTLBuffer> buffer(size_t bytes,bool shared){
        return [device newBufferWithLength:bytes options:shared?MTLResourceStorageModeShared:MTLResourceStorageModePrivate];
    }
};
void dispatch(id<MTLComputeCommandEncoder> enc,id<MTLComputePipelineState> pipeline,int w,int h){
    [enc setComputePipelineState:pipeline];
    auto x=pipeline.threadExecutionWidth;
    auto y=std::min<NSUInteger>(8,pipeline.maxTotalThreadsPerThreadgroup/x);
    [enc dispatchThreadgroups:MTLSizeMake((w+x-1)/x,(h+y-1)/y,1)
        threadsPerThreadgroup:MTLSizeMake(x,y,1)];
    [enc endEncoding];
}
}
bool metalShutter(Image now,const Image* prev,const Image* next,Image dst,const int* win,float span,int curve,bool draft,int fusionCount,const CameraPair* camera){
    @autoreleasepool {
        static Engine engine;
        if(!engine.queue || !engine.kernels[4] || (!prev && !next))return false;
        if(now.w!=dst.w||now.h!=dst.h||now.x0!=dst.x0||now.y0!=dst.y0)return false;
        Geometry g{};g.width=now.w;g.height=now.h;g.grid=draft?16:8;
        g.fieldWidth=(now.w-1)/g.grid+2;g.fieldHeight=(now.h-1)/g.grid+2;
        g.hasPrev=prev!=nullptr;g.hasNext=next!=nullptr;g.curve=curve;g.samples=draft?16:(camera?192:64);g.exposure=span;g.fusionCount=fusionCount;g.cinema=camera!=nullptr;
        int w=now.w,h=now.h;
        size_t elements=0;
        for(int l=0;l<7;++l){
            if(elements+size_t(w)*h>INT32_MAX)return false;
            g.widths[l]=w;g.heights[l]=h;g.offsets[l]=int(elements);++g.levels;
            elements+=size_t(w)*h;
            if(std::min(w,h)<32)break;
            w=(w+1)/2;h=(h+1)/2;
        }
        const size_t row=size_t(now.w)*16,bytes=row*now.h;
        std::unique_ptr<Scratch> scratch;
        {
            std::lock_guard<std::mutex> lock(engine.cacheMutex);
            scratch=std::move(engine.idle);
        }
        if(!scratch || scratch->width!=now.w || scratch->height!=now.h){
            scratch=std::make_unique<Scratch>();scratch->width=now.w;scratch->height=now.h;
        }
        auto acquire=[&](int slot,size_t length,bool shared)->id<MTLBuffer>{
            if([scratch->slots[slot] length]<length)scratch->slots[slot]=engine.buffer(length,shared);
            return scratch->slots[slot];
        };
        id<MTLCommandBuffer> cmd=[engine.queue commandBuffer];
        if(!cmd)return false;
        auto encode=[&](){return [cmd computeCommandEncoder];};
        id<MTLBuffer> pixels[3]={nil,nil,nil},pyr[3]={nil,nil,nil},fields[2]={nil,nil};
        const Image* frames[]={&now,prev,next};
        for(int i=0;i<3;++i){
            if(!frames[i])continue;
            pixels[i]=acquire(i,bytes,true);pyr[i]=acquire(3+i,elements*sizeof(float),false);
            if(!pixels[i]||!pyr[i])return false;
            auto& im=*frames[i];
            if(im.w!=now.w||im.h!=now.h)return false;
            auto packed=static_cast<char*>([pixels[i] contents]);
            for(int y=0;y<im.h;++y)std::memcpy(packed+y*row,im.at(im.x0,im.y0+y),row);
            auto enc=encode();if(!enc)return false;
            [enc setBuffer:pixels[i] offset:0 atIndex:0];[enc setBuffer:pyr[i] offset:0 atIndex:1];
            [enc setBytes:&g length:sizeof(g) atIndex:2];
            dispatch(enc,engine.kernels[0],now.w,now.h);
            for(int l=1;l<g.levels;++l){
                enc=encode();if(!enc)return false;
                [enc setBuffer:pyr[i] offset:0 atIndex:0];[enc setBytes:&g length:sizeof(g) atIndex:1];
                [enc setBytes:&l length:sizeof(l) atIndex:2];
                dispatch(enc,engine.kernels[1],g.widths[l],g.heights[l]);
            }
            if(i){
                fields[i-1]=acquire(5+i,size_t(g.fieldWidth)*g.fieldHeight*2*sizeof(float),false);
                if(!fields[i-1])return false;
                enc=encode();if(!enc)return false;
                [enc setBuffer:pyr[0] offset:0 atIndex:0];[enc setBuffer:pyr[i] offset:0 atIndex:1];
                [enc setBuffer:fields[i-1] offset:0 atIndex:2];[enc setBytes:&g length:sizeof(g) atIndex:3];
                CameraPair pair=camera?camera[i-1]:CameraPair{};
                [enc setBytes:&pair length:sizeof(pair) atIndex:4];
                dispatch(enc,engine.kernels[2],g.fieldWidth,g.fieldHeight);
            }
        }
        id<MTLBuffer> linear=pixels[0];
        if(curve){
            // The neighboring RGBA input is no longer needed after its luma pass.
            linear=(fusionCount || g.cinema)?acquire(9,bytes,false):(prev?pixels[1]:pixels[2]);
            if(!linear)return false;
            auto dec=encode();if(!dec)return false;
            [dec setBuffer:pixels[0] offset:0 atIndex:0];[dec setBuffer:linear offset:0 atIndex:1];
            [dec setBytes:&g length:sizeof(g) atIndex:2];dispatch(dec,engine.kernels[4],now.w,now.h);
        }
        auto out=acquire(8,bytes,true);auto enc=encode();
        if(!enc || !out)return false;
        [enc setBuffer:pixels[0] offset:0 atIndex:0];[enc setBuffer:out offset:0 atIndex:1];
        [enc setBuffer:(prev?fields[0]:fields[1]) offset:0 atIndex:2];
        [enc setBuffer:(next?fields[1]:fields[0]) offset:0 atIndex:3];
        [enc setBuffer:linear offset:0 atIndex:5];
        [enc setBuffer:(prev?pixels[1]:pixels[0]) offset:0 atIndex:6];
        [enc setBuffer:(next?pixels[2]:pixels[0]) offset:0 atIndex:7];
        [enc setBytes:&g length:sizeof(g) atIndex:4];dispatch(enc,engine.kernels[3],now.w,now.h);
        [cmd commit];[cmd waitUntilCompleted];
        if(cmd.status!=MTLCommandBufferStatusCompleted)return false;
        int x=std::max(win[0],dst.x0),end=std::min(win[2],dst.x0+dst.w);
        auto packed=static_cast<const float*>([out contents]);
        if(end>x)for(int y=std::max(win[1],dst.y0);y<std::min(win[3],dst.y0+dst.h);++y)
            std::memcpy(dst.at(x,y),packed+4*(size_t(y-dst.y0)*dst.w+x-dst.x0),size_t(end-x)*16);
        {
            std::lock_guard<std::mutex> lock(engine.cacheMutex);
            if(!engine.idle)engine.idle=std::move(scratch);
        }
        return true;
    }
}
}
