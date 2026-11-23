R"MSL(
#include <metal_stdlib>
using namespace metal;
struct Geometry {
    int width,height,grid,fieldWidth,fieldHeight,levels;
    int widths[7],heights[7],offsets[7];
    int hasPrev,hasNext,curve,samples;
    float exposure; int fusionCount,cinema;
};
struct CameraPair { float forward[9], reverse[9]; };
kernel void luma(device const float4* pixels [[buffer(0)]],device float* pyr [[buffer(1)]],
                 constant Geometry& g [[buffer(2)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=uint(g.width)||pos.y>=uint(g.height))return;
    uint i=pos.y*g.width+pos.x;
    pyr[i]=dot(pixels[i].rgb,float3(.25,.5,.25));
}
int indexAt(constant Geometry& g,int level,int2 p){
    p=clamp(p,int2(0),int2(g.widths[level]-1,g.heights[level]-1));
    return g.offsets[level]+p.y*g.widths[level]+p.x;
}
kernel void reducePlane(device float* pyr [[buffer(0)]],constant Geometry& g [[buffer(1)]],
                        constant int& level [[buffer(2)]],uint2 pos [[thread_position_in_grid]]) {
    if(pos.x>=uint(g.widths[level])||pos.y>=uint(g.heights[level]))return;
    int2 p=int2(pos)*2;
    float sum=0;
    for(int j=0;j<2;++j)for(int i=0;i<2;++i)sum+=pyr[indexAt(g,level-1,p+int2(i,j))];
    pyr[indexAt(g,level,int2(pos))]=.25f*sum;
}
int2 track(device const float* a,device const float* b,constant Geometry& g,int2 p,constant float* h){
    int2 delta=0;
    for(int level=g.levels-1;level>=0;--level){
        int2 center=p>>level,base=delta*2;
        float ref[25];
        for(int j=0;j<5;++j)for(int k=0;k<5;++k)
            ref[j*5+k]=a[indexAt(g,level,center+int2(k-2,j-2))];
        float best=INFINITY;
        for(int v=-2;v<=2;++v)for(int u=-2;u<=2;++u){
            int2 q=base+int2(u,v);
            float cost=0;
            int2 origin=center+q-2;
            bool inside=all(origin>=int2(0)) && all(origin+5<=int2(g.widths[level],g.heights[level]));
            for(int j=0;j<5;++j){
                int row=g.offsets[level]+(origin.y+j)*g.widths[level]+origin.x;
                for(int k=0;k<5;++k){
                    int idx=inside?row+k:indexAt(g,level,origin+int2(k,j));
                    cost+=abs(ref[j*5+k]-b[idx]);
                }
            }
            if(cost<best || (cost==best && q.x*q.x+q.y*q.y<delta.x*delta.x+delta.y*delta.y)){
                delta=q;best=cost;
            }
        }
        if(g.fusionCount && level==0){
            for(int v=-4;v<=4;++v)for(int u=-4;u<=4;++u){
                int2 q=int2(u,v);
                float cost=0;
                for(int j=0;j<5;++j)for(int k=0;k<5;++k)
                    cost+=abs(ref[j*5+k]-b[indexAt(g,level,center+q+int2(k-2,j-2))]);
                if(cost<best || (cost==best && u*u+v*v<delta.x*delta.x+delta.y*delta.y)){
                    best=cost;delta=q;
                }
            }
        }
        if(level==0 && h[8]!=0.f){
            float2 halfSize=.5f*float2(max(1,g.width-1),max(1,g.height-1));
            float2 uv=clamp(float2(p)/halfSize-1.f,float2(-1),float2(1));
            float denom=h[6]*uv.x+h[7]*uv.y+1.f;
            float2 projected=float2(h[0]*uv.x+h[1]*uv.y+h[2],h[3]*uv.x+h[4]*uv.y+h[5])/denom;
            float2 shift=halfSize*(projected-uv);
            int2 baseCamera=int2(round(shift));
            for(int v=-2;v<=2;++v)for(int u=-2;u<=2;++u){
                int2 q=baseCamera+int2(u,v);float cost=0;
                for(int j=0;j<5;++j)for(int k=0;k<5;++k)
                    cost+=abs(ref[j*5+k]-b[indexAt(g,0,center+q+int2(k-2,j-2))]);
                if(cost<best || (cost==best && distance(float2(q),shift)<distance(float2(delta),shift))){
                    best=cost;delta=q;
                }
            }
        }
    }
    return delta;
}
kernel void flow(device const float* a [[buffer(0)]],device const float* b [[buffer(1)]],
                 device float2* field [[buffer(2)]],constant Geometry& g [[buffer(3)]],
                 constant CameraPair& camera [[buffer(4)]],uint2 pos [[thread_position_in_grid]]){
    if(pos.x>=uint(g.fieldWidth)||pos.y>=uint(g.fieldHeight))return;
    int2 pt=min(int2(pos)*g.grid,int2(g.width-1,g.height-1));
    int2 d=track(a,b,g,pt,camera.forward);
    int2 roundTrip=d+track(b,a,g,pt+d,camera.reverse);
    float xx=0,xy=0,yy=0,bx=0,by=0,residual=0,still=0;
    for(int j=-2;j<=2;++j)for(int i=-2;i<=2;++i){
        int2 p=pt+int2(i,j),q=p+d;
        float ref=a[indexAt(g,0,p)],r=ref-b[indexAt(g,0,q)];
        float gx=.5f*(b[indexAt(g,0,q+int2(1,0))]-b[indexAt(g,0,q-int2(1,0))]);
        float gy=.5f*(b[indexAt(g,0,q+int2(0,1))]-b[indexAt(g,0,q-int2(0,1))]);
        xx+=gx*gx;xy+=gx*gy;yy+=gy*gy;bx+=gx*r;by+=gy*r;
        residual+=abs(r);still+=abs(ref-b[indexAt(g,0,p)]);
    }
    float ridge=1.e-7f+.005f*(xx+yy);
    xx+=ridge;yy+=ridge;
    float det=xx*yy-xy*xy;
    float2 result=float2(d);
    if(det>1.e-15f)result+=clamp(float2(yy*bx-xy*by,xx*by-xy*bx)/det,float2(-.65f),float2(.65f));
    if(length(float2(roundTrip))>2.f && residual>=.25f*still)result=float2(0);
    field[pos.y*g.fieldWidth+pos.x]=result;
}
float2 vectorAt(device const float2* f,constant Geometry& g,uint2 pos){
    uint2 cell=pos/uint(g.grid);
    float2 t=float2(pos%uint(g.grid))/float(g.grid);
    uint i=cell.y*g.fieldWidth+cell.x;
    return mix(mix(f[i],f[i+1],t.x),mix(f[i+g.fieldWidth],f[i+g.fieldWidth+1],t.x),t.y);
}
float motionScore(device const float4* src,device const float4* neighbor,constant Geometry& g,uint2 pos,float2 v){
    int2 end=int2(g.width-1,g.height-1);float sum=0;
    float3 origin=src[pos.y*g.width+pos.x].rgb;
    for(int k=0;k<5;++k){
        int2 p=clamp(int2(pos)+int2(int(k==1)-int(k==2),int(k==3)-int(k==4)),int2(0),end);
        int2 q=clamp(p+int2(round(v)),int2(0),end);
        float3 a=src[p.y*g.width+p.x].rgb,b=neighbor[q.y*g.width+q.x].rgb;
        sum+=dot(abs(a-b),float3(1))/(1.f+12.f*dot(abs(a-origin),float3(1)));
    }
    return sum;
}
float2 guidedVector(device const float2* field,device const float4* src,device const float4* neighbor,
                    constant Geometry& g,uint2 pos){
    float2 smooth=vectorAt(field,g,pos);
    if(!g.cinema)return smooth;
    uint2 cell=pos/uint(g.grid);
    uint i=cell.y*g.fieldWidth+cell.x;
    float2 candidates[5]={field[i],field[i+1],field[i+g.fieldWidth],field[i+g.fieldWidth+1],float2(0)};
    float spread=0;
    for(int j=0;j<4;++j)spread=max(spread,dot(abs(candidates[j]-smooth),float2(1)));
    if(spread<2.f)return smooth;
    float error=motionScore(src,neighbor,g,pos,smooth);
    float2 result=smooth;
    for(int j=0;j<5;++j){
        float other=motionScore(src,neighbor,g,pos,candidates[j]);
        if(other+.0005f<error*.94f){result=candidates[j];error=other;}
    }
    return result;
}
float decodeChannel(float v,int c){
    if(c==1)return v>=171.2102946929f/1023.f?.19f*pow(10.f,(v*1023.f-420.f)/261.5f)-.01f:(v*1023.f-95.f)*.01125f/(171.2102946929f-95.f);
    if(c==2)return v<=.02740668f?v/10.44426855f:exp2(v/.07329248f-7.f)-.0075f;
    return v;
}
float encodeChannel(float v,int c){
    if(c==1)return v>=.01125f?(420.f+261.5f*log10((v+.01f)/.19f))/1023.f:(95.f+v*(171.2102946929f-95.f)/.01125f)/1023.f;
    if(c==2)return v<=.00262409f?v*10.44426855f:(log2(v+.0075f)+7.f)*.07329248f;
    return v;
}
kernel void linearize(device const float4* src [[buffer(0)]],device float4* dst [[buffer(1)]],
                      constant Geometry& g [[buffer(2)]],uint2 pos [[thread_position_in_grid]]){
    if(pos.x>=uint(g.width)||pos.y>=uint(g.height))return;
    uint i=pos.y*g.width+pos.x;
    float4 p=src[i];
    dst[i]=float4(decodeChannel(p.r,g.curve),decodeChannel(p.g,g.curve),decodeChannel(p.b,g.curve),p.a);
}
float4 sampleFrame(device const float4* img,float2 point,constant Geometry& g,int curve,float alpha){
    point=clamp(point,float2(0),float2(g.width-1,g.height-1));
    int2 base=int2(point);float2 f=point-float2(base);
    float3 sum=0;
    for(int y=0;y<2;++y)for(int x=0;x<2;++x){
        float w=(x?f.x:1-f.x)*(y?f.y:1-f.y);
        if(w<=0)continue;
        int2 pt=min(base+int2(x,y),int2(g.width-1,g.height-1));
        float4 p=img[pt.y*g.width+pt.x];if(!(abs(p.a-alpha)<=1.e-5f))return float4(0);
        sum+=w*float3(decodeChannel(p.r,curve),decodeChannel(p.g,curve),decodeChannel(p.b,curve));
    }
    return float4(sum,1);
}
kernel void integrateFrame(device const float4* src [[buffer(0)]],device float4* out [[buffer(1)]],
                    device const float2* prev [[buffer(2)]],device const float2* next [[buffer(3)]],
                    constant Geometry& g [[buffer(4)]],device const float4* linearPixels [[buffer(5)]],device const float4* earlier [[buffer(6)]],device const float4* later [[buffer(7)]],uint2 pos [[thread_position_in_grid]]){
    if(pos.x>=uint(g.width)||pos.y>=uint(g.height))return;
    uint i=pos.y*g.width+pos.x;
    float4 center=src[i];
    float2 a=g.hasPrev?guidedVector(prev,src,earlier,g,pos):float2(0);
    float2 b=g.hasNext?guidedVector(next,src,later,g,pos):-a;
    if(!g.hasPrev)a=-b;
    float span=max(length(a),length(b))*g.exposure;
    if(g.fusionCount){
        bool stationary=true;
        for(int dx=-1;dx<=1;++dx){
            uint k=pos.y*g.width+uint(clamp(int(pos.x)+dx,0,g.width-1));
            stationary=stationary && all(src[k]==earlier[k]) && all(src[k]==later[k]);
        }
        if(stationary){out[i]=center;return;}
        float aa=dot(a,a),bb=dot(b,b);
        bool fit=g.cinema && max(aa,bb)<4.f*min(aa,bb);
        if(fit && dot(a,b)>=0.f){
            float4 p=sampleFrame(earlier,float2(pos)+a,g,g.curve,center.a);
            float4 n=sampleFrame(later,float2(pos)+b,g,g.curve,center.a);
            float3 ref=linearPixels[i].rgb;
            fit=p.a>0 && n.a>0 && all(abs(ref-p.rgb)<=.012f+.18f*max(abs(ref),abs(p.rgb)))
                               && all(abs(ref-n.rgb)<=.012f+.18f*max(abs(ref),abs(n.rgb)));
        }
        int count=g.fusionCount>0?g.fusionCount:clamp(int(ceil(2.f*span)),4,g.samples);
        float3 sum=0;
        for(int s=0;s<count;++s){
            float t=((s+.5f)/count-.5f)*g.exposure;
            float f=abs(t);float2 v=t<0?a:b;
            float2 shift=f*v;
            if(fit && f<=1.f)
                shift=.5f*(t*(b-a)+t*t*(b+a));
            float2 p=float2(pos)-shift;
            float4 cur=sampleFrame(linearPixels,p,g,0,center.a);
            if(cur.a==0){out[i]=center;return;}
            if(f<=1.f){
                float4 other=sampleFrame(t<0?earlier:later,p+v,g,g.curve,center.a);
                float3 diff=abs(cur.rgb-other.rgb),peak=max(abs(cur.rgb),abs(other.rgb));
                float weight=f*clamp(1.f-max(diff.x,max(diff.y,diff.z))/(.02f+.35f*max(.03f,max(peak.x,max(peak.y,peak.z)))),0.f,1.f);
                cur.rgb=mix(cur.rgb,other.rgb,other.a*weight);
            }
            sum+=cur.rgb;
        }
        sum/=float(count);
        out[i]=float4(encodeChannel(sum.x,g.curve),encodeChannel(sum.y,g.curve),encodeChannel(sum.z,g.curve),center.a);return;
    }
    if(span<.01f){out[i]=center;return;}
    int count=clamp(int(ceil(span*2.f)),4,g.samples);
    float3 sum=0;
    for(int s=0;s<count;++s){
        float t=((float(s)+.5f)/float(count)-.5f)*g.exposure;
        float2 point=clamp(float2(pos)-abs(t)*(t<0?a:b),float2(0),float2(g.width-1,g.height-1));
        int2 base=int2(point);
        float2 frac=point-float2(base);
        for(int y=0;y<2;++y)for(int x=0;x<2;++x){
            float w=(x?frac.x:1-frac.x)*(y?frac.y:1-frac.y);
            if(w==0)continue;
            int2 pt=min(base+int2(x,y),int2(g.width-1,g.height-1));
            float4 pixel=linearPixels[pt.y*g.width+pt.x];
            if(!(abs(pixel.a-center.a)<=1.e-5f)){out[i]=center;return;}
            sum+=w*pixel.rgb;
        }
    }
    sum/=float(count);
    out[i]=float4(encodeChannel(sum.r,g.curve),encodeChannel(sum.g,g.curve),encodeChannel(sum.b,g.curve),center.a);
}
)MSL"
