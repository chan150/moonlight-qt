// Nasty hack to avoid conflict between AVFoundation and
// libavutil both defining AVMediaType
#define AVMediaType AVMediaType_FFmpeg
#include "vt.h"
#include "pacer/pacer.h"
#undef AVMediaType

#include <SDL_syswm.h>
#include <Limelight.h>

#include <mach/mach_time.h>
#import <Cocoa/Cocoa.h>
#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>

class VTRenderer : public IFFmpegRenderer
{
public:
    VTRenderer()
        : m_HwContext(nullptr),
          m_DisplayLayer(nullptr),
          m_FormatDesc(nullptr),
          m_View(nullptr)
    {
    }

    virtual ~VTRenderer()
    {
        if (m_HwContext != nullptr) {
            av_buffer_unref(&m_HwContext);
        }

        if (m_FormatDesc != nullptr) {
            CFRelease(m_FormatDesc);
        }

        if (m_View != nullptr) {
            [m_View removeFromSuperview];
        }
    }

    // Caller frees frame after we return
    virtual void renderFrameAtVsync(AVFrame* frame) override
    {
        OSStatus status;
        CVPixelBufferRef pixBuf = reinterpret_cast<CVPixelBufferRef>(frame->data[3]);

        if (m_DisplayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                        "Resetting failed AVSampleBufferDisplay layer");

            // Trigger the main thread to recreate the decoder
            SDL_Event event;
            event.type = SDL_RENDER_TARGETS_RESET;
            SDL_PushEvent(&event);
            return;
        }

        // If the format has changed or doesn't exist yet, construct it with the
        // pixel buffer data
        if (!m_FormatDesc || !CMVideoFormatDescriptionMatchesImageBuffer(m_FormatDesc, pixBuf)) {
            if (m_FormatDesc != nullptr) {
                CFRelease(m_FormatDesc);
            }
            status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                                  pixBuf, &m_FormatDesc);
            if (status != noErr) {
                SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                             "CMVideoFormatDescriptionCreateForImageBuffer() failed: %d",
                             status);
                return;
            }
        }

        // Queue this sample for the next v-sync
        CMSampleTimingInfo timingInfo = {
            .duration = kCMTimeInvalid,
            .decodeTimeStamp = kCMTimeInvalid,
            .presentationTimeStamp = CMTimeMake(mach_absolute_time(), 1000 * 1000 * 1000)
        };

        CMSampleBufferRef sampleBuffer;
        status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                          pixBuf,
                                                          m_FormatDesc,
                                                          &timingInfo,
                                                          &sampleBuffer);
        if (status != noErr) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                         "CMSampleBufferCreateReadyWithImageBuffer() failed: %d",
                         status);
            return;
        }

        [m_DisplayLayer enqueueSampleBuffer:sampleBuffer];

        CFRelease(sampleBuffer);
    }

    virtual bool initialize(SDL_Window* window,
                            int videoFormat,
                            int,
                            int,
                            int,
                            bool) override
    {
        int err;

        if (videoFormat & VIDEO_FORMAT_MASK_H264) {
            // Prior to 10.13, we'll just assume everything has
            // H.264 support and fail open to allow VT decode.
    #if __MAC_OS_X_VERSION_MAX_ALLOWED >= 101300
            if (__builtin_available(macOS 10.13, *)) {
                if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)) {
                    SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                                "No HW accelerated H.264 decode via VT");
                    return false;
                }
            }
            else
    #endif
            {
                SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                            "Assuming H.264 HW decode on < macOS 10.13");
            }
        }
        else if (videoFormat & VIDEO_FORMAT_MASK_H265) {
    #if __MAC_OS_X_VERSION_MAX_ALLOWED >= 101300
            if (__builtin_available(macOS 10.13, *)) {
                if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
                    SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                                "No HW accelerated HEVC decode via VT");
                    return false;
                }
            }
            else
    #endif
            {
                // Fail closed for HEVC if we're not on 10.13+
                SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                            "No HEVC support on < macOS 10.13");
                return false;
            }
        }

        SDL_SysWMinfo info;

        SDL_VERSION(&info.version);

        if (!SDL_GetWindowWMInfo(window, &info)) {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                        "SDL_GetWindowWMInfo() failed: %s",
                        SDL_GetError());
            return false;
        }

        SDL_assert(info.subsystem == SDL_SYSWM_COCOA);

        // SDL adds its own content view to listen for events.
        // We need to add a subview for our display layer.
        NSView* contentView = info.info.cocoa.window.contentView;
        m_View = [[NSView alloc] initWithFrame:contentView.bounds];

        m_DisplayLayer = [[AVSampleBufferDisplayLayer alloc] init];
        m_DisplayLayer.bounds = m_View.bounds;
        m_DisplayLayer.position = CGPointMake(CGRectGetMidX(m_View.bounds), CGRectGetMidY(m_View.bounds));
        m_DisplayLayer.videoGravity = AVLayerVideoGravityResizeAspect;

        // Create a layer-hosted view by setting the layer before wantsLayer
        // This avoids us having to add our AVSampleBufferDisplayLayer as a
        // sublayer of a layer-backed view which leaves a useless layer in
        // the middle.
        m_View.layer = m_DisplayLayer;
        m_View.wantsLayer = YES;

        [contentView addSubview: m_View];

        err = av_hwdevice_ctx_create(&m_HwContext,
                                     AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                                     nullptr,
                                     nullptr,
                                     0);
        if (err < 0) {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                        "av_hwdevice_ctx_create() failed for VT decoder: %d",
                        err);
            return false;
        }

        return true;
    }

    virtual bool prepareDecoderContext(AVCodecContext* context) override
    {
        context->hw_device_ctx = av_buffer_ref(m_HwContext);

        SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION,
                    "Using VideoToolbox accelerated renderer");

        return true;
    }

    virtual bool needsTestFrame() override
    {
        // We query VT to determine whether the codec is supported
        return false;
    }

    virtual int getDecoderCapabilities() override
    {
        return 0;
    }

    virtual IFFmpegRenderer::VSyncConstraint getVsyncConstraint() override
    {
        // This renderer is inherently tied to V-sync due how we're
        // rendering with AVSampleBufferDisplay layer. Running without
        // the V-Sync source leads to massive stuttering.
        return VSYNC_FORCE_ON;
    }

private:
    AVBufferRef* m_HwContext;
    AVSampleBufferDisplayLayer* m_DisplayLayer;
    CMVideoFormatDescriptionRef m_FormatDesc;
    NSView* m_View;
};

IFFmpegRenderer* VTRendererFactory::createRenderer() {
    return new VTRenderer();
}
