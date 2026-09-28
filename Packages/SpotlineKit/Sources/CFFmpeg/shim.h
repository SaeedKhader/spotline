// FFmpeg's demuxing, decoding, resampling and scaling libraries, used for
// waveform peaks and shot-change detection. Development builds link
// Homebrew's FFmpeg (installed with mpv); see docs/ARCHITECTURE.md section 7.
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

// Error codes are macros Swift cannot import.
static inline int spotline_averror_eagain(void) { return AVERROR(EAGAIN); }
static inline int spotline_averror_eof(void) { return AVERROR_EOF; }
