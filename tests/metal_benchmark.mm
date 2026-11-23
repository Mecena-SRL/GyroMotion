#import <Metal/Metal.h>
#include "camera.hpp"
#include "exposure.hpp"
#include <chrono>
#include <cstdio>
namespace motion { bool metalShutter(Image,const Image*,const Image*,Image,const int*,float,int,bool,int=0,const CameraPair* = nullptr); }
using namespace motion;
struct Frames {
    std::vector<float> data[4];
    Image image[4];
    Frames(int w,int h){
        for(int f=0;f<4;++f){
            data[f].resize(size_t(w)*h*4);
            image[f]={data[f].data(),0,0,w,h,w*16};
            if(f==3)continue;
            for(int y=0;y<h;++y)for(int x=0;x<w;++x){
                unsigned seed=unsigned((x-4*f+w)%w)+unsigned(y)*1009;
                seed=(seed^(seed>>16))*0x45d9f3bU;
                float v=float(seed%251)/255.f;
                auto px=image[f].at(x,y);
                px[0]=v*1.6f;px[1]=v;px[2]=.5f*v;px[3]=1.f;
            }
        }
    }
    bool gpu(bool draft,int curve,bool cinema=false){
        int bounds[]={0,0,image[0].w,image[0].h};
        if(cinema){
            CameraSamples center(image[1]);
            CameraPair pairs[]={analysePair(center,CameraSamples(image[0]),image[1].w,image[1].h).camera,
                                analysePair(center,CameraSamples(image[2]),image[1].w,image[1].h).camera};
            auto source=imageExposureFraction(image[0],image[1],image[2],curve);
            float span=float(std::sqrt(std::max(0.,.25-std::pow(source.value_or(0.),2))));
            return metalShutter(image[1],&image[0],&image[2],image[3],bounds,span,curve,draft,-1,pairs);
        }
        return metalShutter(image[1],&image[0],&image[2],image[3],bounds,.5f,curve,draft);
    }
};
int main(){@autoreleasepool {
    auto device=MTLCreateSystemDefaultDevice();
    if(!device){std::puts("Metal non disponibile: percorso CPU.");return 0;}
    Frames small(320,128);
    small.image[1].at(117,65)[3]=.4f;
    auto p=pyramid(small.image[1]);
    auto a=estimate(p,pyramid(small.image[0])), b=estimate(p,pyramid(small.image[2]));
    for(int curve:{Linear,SLog3,Intermediate}){
        if(!small.gpu(false,curve)){std::fputs("Errore nel render Metal\n",stderr);return 1;}
        double error=0;int count=0;
        for(int y=8;y<120;++y)for(int x=12;x<308;++x){
            float ref[4];
            integrate(small.image[1],x,y,a.sample(x,y),b.sample(x,y),.5f,curve,ref);
            auto pix=small.image[3].at(x,y);
            for(int k=0;k<3;++k){if(!std::isfinite(pix[k]))return 2;error+=std::abs(ref[k]-pix[k]);++count;}
            if(pix[3]!=ref[3])return 3;
        }
        std::printf("Metal HQ / CPU: curva %d, errore medio %.7f\n",curve,error/count);
        if(error/count>.004)return 4;
    }
    a=estimate(p,pyramid(small.image[0]),8,true);b=estimate(p,pyramid(small.image[2]),8,true);
    int window[]={0,0,320,128};
    for(int curve:{Linear,SLog3,Intermediate}){
        if(!metalShutter(small.image[1],&small.image[0],&small.image[2],small.image[3],window,1.f,curve,false,4))return 7;
        double error=0;int count=0;
        for(int y=8;y<120;++y)for(int x=12;x<308;++x){
            float ref[4];
            reconstruct(small.image[1],&small.image[0],&small.image[2],x,y,a.sample(x,y),b.sample(x,y),1.f,4,curve,ref);
            for(int c=0;c<3;++c){error+=std::abs(ref[c]-small.image[3].at(x,y)[c]);++count;}
        }
        if(!std::isfinite(error)||error/count>.004)return 8;
    }
    CameraSamples center(small.image[1]);
    CameraPair pairs[2];
    for(int side=0;side<2;++side)
        pairs[side]=analysePair(center,CameraSamples(small.image[2*side]),320,128).camera;
    a=estimate(p,pyramid(small.image[0]),8,true,&pairs[0].forward,&pairs[0].reverse);
    b=estimate(p,pyramid(small.image[2]),8,true,&pairs[1].forward,&pairs[1].reverse);
    for(int curve:{Linear,SLog3,Intermediate}){
        if(!metalShutter(small.image[1],&small.image[0],&small.image[2],small.image[3],window,.5f,curve,false,-1,pairs))return 12;
        double error=0;int count=0;
        for(int y=8;y<120;++y)for(int x=12;x<308;++x){
            Vec va=guidedSample(a,small.image[1],small.image[0],x,y),vb=guidedSample(b,small.image[1],small.image[2],x,y);
            int n=std::clamp(int(std::ceil(std::max(std::hypot(va.x,va.y),std::hypot(vb.x,vb.y)))),4,192);
            float ref[4];reconstruct(small.image[1],&small.image[0],&small.image[2],x,y,va,vb,.5f,n,curve,ref,true);
            for(int c=0;c<3;++c){error+=std::abs(ref[c]-small.image[3].at(x,y)[c]);++count;}
        }
        std::printf("Cinema Metal / CPU | curva %d | MAE %.7f\n",curve,error/count);
        if(!std::isfinite(error) || error/count>.004)return 13;
    }
    // The RGB payload may be present even when the spare alpha channel is zero.
    for(size_t k=3;k<small.data[0].size();k+=4)
        for(int f=0;f<3;++f)small.data[f][k]=1.f;
    for(int slices:{0,4}){
        if(!metalShutter(small.image[1],&small.image[0],&small.image[2],small.image[3],window,1.f,Linear,false,slices))return 9;
        auto opaque=small.data[3];
        for(size_t k=3;k<opaque.size();k+=4)
            for(int f=0;f<3;++f)small.data[f][k]=0.f;
        if(!metalShutter(small.image[1],&small.image[0],&small.image[2],small.image[3],window,1.f,Linear,false,slices))return 10;
        for(size_t k=0;k<opaque.size();++k)
            if(std::abs(small.data[3][k]-(k%4==3?0.f:opaque[k]))>1e-5f)return 11;
        for(size_t k=3;k<opaque.size();k+=4)
            for(int f=0;f<3;++f)small.data[f][k]=1.f;
    }
    for(int w:{1920,3840}){
        Frames f(w,w*9/16);
        for(bool draft:{true,false}){
            if(!f.gpu(draft,Linear,true))return 5;
            std::vector<double> elapsed;
            for(int i=0;i<3;++i){
                auto start=std::chrono::steady_clock::now();
                if(!f.gpu(draft,Linear,true))return 6;
                elapsed.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count());
            }
            std::sort(elapsed.begin(),elapsed.end());
            std::printf("Cinema · analisi + Metal | %s | %dx%d | %s | %.1f ms/frame (%.1f fps)\n",
                device.name.UTF8String,w,w*9/16,draft?"Fluida":"Alta qualità",elapsed[1],1000/elapsed[1]);
        }
    }
    return 0;
}}
