/*
 * speakerfx.cpp -- libgaokunspeakerfx.so, the speaker processing behind the
 * audio HAL's playback hook (patches/0117).
 *
 * WHERE IT RUNS
 * The AIDL audio HAL (StreamPrimary) hands every playback block to
 * playback_hook_process() right before writing it into ALSA, in place.  That
 * is after AudioFlinger has mixed everything, games' FAST tracks included --
 * which no session effect ever sees (AudioFlinger refuses software effects on
 * a FAST session, "non HW effect ... in fast mode") -- so the bass chain and
 * its ceiling cover every sound the speakers play.  The HAL finds this
 * library through ro.vendor.audio.primary.playback_hook (device.mk).
 *
 * THE CONTRACT (C linkage, all on the stream's worker thread)
 *   void *playback_hook_open(int card, int device, int sampleRate,
 *                            int channelCount, int pcmFormat);
 *       Called when the stream opens its ALSA device.  nullptr means "not
 *       mine": the HAL then never calls process() for that stream.  This
 *       library takes the built-in speaker PCM only (card 0, device 1, see
 *       bin/audio-route.sh), 48 kHz stereo, S16_LE or S32_LE (tinyalsa's
 *       enum pcm_format: 0 and 1).
 *   void playback_hook_process(void *handle, void *buffer, size_t frames);
 *       In place.  No allocation, no lock, bounded time.
 *   void playback_hook_close(void *handle);
 *       Called on standby / shutdown / device change.
 *
 * WHEN IT PROCESSES
 * Only while the speaker enhancement is on (vendor.gaokun3.histen.on = 1,
 * init's mirror of the Parts switch) with persist.vendor.gaokun3.histen.engine
 * = bass; the session effect is a wire then (gaokun_effect.cpp), so nothing
 * is processed twice.  Otherwise the buffer is left alone -- except for the
 * mixer boost below.  The switch, the engine and the boost are re-read every
 * 100 ms; the effect re-reads the engine every 16 buffers, so changing the
 * engine mid-stream can process a stream twice (or not at all) for well
 * under a second, with this chain's limiter still holding the ceiling.
 *
 * MIXER BOOST
 * With engine = bass, audio-route.sh sets the WSA digital volume 6 dB higher
 * at boot (78 -> 84) and publishes that in vendor.gaokun3.histen.boost; it
 * stays there whatever the switch does.  While the chain runs, its makeup
 * gives the 6 dB back, so the loudness does not change and the chain's
 * -1 dBFS ceiling sits 6 dB closer to what the amplifiers can do.  While it
 * does not (switch off, or the engine changed after boot), the buffer is
 * attenuated by the boost instead.  Either way no sound is louder than at
 * the normal mixer setting.
 *
 * KNOBS (re-read about once a second; vendor_gaokun3_prop, root to set)
 *   persist.vendor.gaokun3.histen.bass.lowboost  dB, 0..24        (14)
 *   persist.vendor.gaokun3.histen.bass.lowhp     Hz, 0 or 20..120 (50)
 *   persist.vendor.gaokun3.histen.bass.lowsub    dB, -99..12      (10; <= -60 removes it)
 *   persist.vendor.gaokun3.histen.bass.trim      dB, -12..0       (-3)
 *   persist.vendor.gaokun3.histen.bass.harm      dB, -99..0       (-9; <= -60 off)
 *   persist.vendor.gaokun3.histen.bass.lc        dB/dB, 0..1      (0.15)
 *   persist.vendor.gaokun3.histen.bass.lcmax     dB, 0..18        (12)
 *   persist.vendor.gaokun3.histen.bass.mbc       0 / 1            (1)
 *   persist.vendor.gaokun3.histen.bass.xtc       0..0.9           (0.55; 0 off)
 *   persist.vendor.gaokun3.histen.bass.xtcdist   cm, 15..200      (30)
 *   persist.vendor.gaokun3.histen.bass.xtclo     Hz, 100..2000    (250)
 *   persist.vendor.gaokun3.histen.bass.makeup    dB, -20..12      (4, before the boost)
 *   vendor.gaokun3.histen.bass.ref               1 = A/B reference (not persistent)
 *
 * Built standalone with GAOKUN_SPKFX_MASTER_ONLY (the KernelSU test module
 * for 1.0.0-rc.2, whose effect does not know engine=bass) the engine property
 * is not checked.
 *
 * Log tag gaokun_spkfx: one line per open / state change / knob change, and
 * while processing one line every ~2 s (levels, loudness compensation, gain
 * reduction, boost, cost).
 */
#include <android/log.h>
#include <sys/system_properties.h>
#include <time.h>

#include <cmath>
#include <cstdarg>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <new>

#include "bass_chain.h"

namespace {

constexpr char kTag[] = "gaokun_spkfx";

constexpr int kSpeakerCard = 0;
constexpr int kSpeakerDevice = 1;
constexpr int kFormatS16 = 0;   /* tinyalsa PCM_FORMAT_S16_LE */
constexpr int kFormatS32 = 1;   /* tinyalsa PCM_FORMAT_S32_LE */

constexpr unsigned kGateFrames = 4800;       /* switch, engine and boost every 100 ms */
constexpr unsigned kRefreshFrames = 48000;   /* all knobs about once a second */
constexpr unsigned kStatFrames = 96000;      /* a log line every ~2 s */

constexpr char kMasterProp[] = "vendor.gaokun3.histen.on";
constexpr char kEngineProp[] = "persist.vendor.gaokun3.histen.engine";
constexpr char kBoostProp[] = "vendor.gaokun3.histen.boost";
constexpr char kRefProp[] = "vendor.gaokun3.histen.bass.ref";
#define BASS_PROP(name) "persist.vendor.gaokun3.histen.bass." name

void logi(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    __android_log_vprint(ANDROID_LOG_INFO, kTag, fmt, ap);
    va_end(ap);
}

bool propIs(const char *name, const char *value) {
    char buf[PROP_VALUE_MAX] = {0};
    if (__system_property_get(name, buf) <= 0) return false;
    return std::strcmp(buf, value) == 0;
}

/* Unset, unparsable or out of [lo, hi] gives `fallback`: a stray value must
 * never reach the DSP. */
double prop(const char *name, double lo, double hi, double fallback) {
    char buf[PROP_VALUE_MAX] = {0};
    if (__system_property_get(name, buf) <= 0) return fallback;
    char *end = nullptr;
    const double v = std::strtod(buf, &end);
    if (end == buf || !(v == v) || v < lo || v > hi) return fallback;
    return v;
}

bool wanted() {
#ifdef GAOKUN_SPKFX_MASTER_ONLY
    (void)kEngineProp;
    return propIs(kMasterProp, "1");
#else
    return propIs(kMasterProp, "1") && propIs(kEngineProp, "bass");
#endif
}

/* Knob values; `boostDb` is taken off the makeup. */
gaokun::BassParams readParams(double boostDb) {
    gaokun::BassParams p;
    p.reference = propIs(kRefProp, "1");
    p.lowBoostDb = prop(BASS_PROP("lowboost"), 0.0, 24.0, p.lowBoostDb);
    p.lowHpHz = prop(BASS_PROP("lowhp"), 0.0, 120.0, p.lowHpHz);
    if (p.lowHpHz > 0.0 && p.lowHpHz < 20.0) p.lowHpHz = 20.0;
    p.lowSubDb = prop(BASS_PROP("lowsub"), -99.0, 12.0, p.lowSubDb);
    p.baseTrimDb = prop(BASS_PROP("trim"), -12.0, 0.0, p.baseTrimDb);
    p.vbGainDb = prop(BASS_PROP("harm"), -99.0, 0.0, p.vbGainDb);
    p.lcSlope = prop(BASS_PROP("lc"), 0.0, 1.0, p.lcSlope);
    p.lcMaxDb = prop(BASS_PROP("lcmax"), 0.0, 18.0, p.lcMaxDb);
    p.mbcOn = !propIs(BASS_PROP("mbc"), "0");
    p.xtcK = prop(BASS_PROP("xtc"), 0.0, 0.9, p.xtcK);
    p.xtcDistCm = prop(BASS_PROP("xtcdist"), 15.0, 200.0, p.xtcDistCm);
    p.xtcLoHz = prop(BASS_PROP("xtclo"), 100.0, 2000.0, p.xtcLoHz);
    p.makeupDb = prop(BASS_PROP("makeup"), -20.0, 12.0, p.makeupDb) - boostDb;
    return p;
}

/* The fields readParams() sets -- the only ones that can change. */
bool sameKnobs(const gaokun::BassParams &a, const gaokun::BassParams &b) {
    return a.reference == b.reference && a.lowBoostDb == b.lowBoostDb &&
           a.lowHpHz == b.lowHpHz && a.lowSubDb == b.lowSubDb && a.baseTrimDb == b.baseTrimDb &&
           a.vbGainDb == b.vbGainDb && a.lcSlope == b.lcSlope && a.lcMaxDb == b.lcMaxDb &&
           a.mbcOn == b.mbcOn && a.xtcK == b.xtcK && a.xtcDistCm == b.xtcDistCm &&
           a.xtcLoHz == b.xtcLoHz && a.makeupDb == b.makeupDb;
}

void logParams(const char *why, const gaokun::BassParams &p, double boostDb) {
    logi("%s: ref=%d lowboost=%.1f lowhp=%.0f lowsub=%.1f trim=%.1f harm=%.1f lc=%.2f/max%.0f "
         "mbc=%d xtc=%.2f@%.0fcm/%.0fHz makeup=%+.1fdB (boost %.0fdB taken off)",
         why, p.reference ? 1 : 0, p.lowBoostDb, p.lowHpHz, p.lowSubDb, p.baseTrimDb, p.vbGainDb,
         p.lcSlope, p.lcMaxDb, p.mbcOn ? 1 : 0, p.xtcK, p.xtcDistCm, p.xtcLoHz, p.makeupDb, boostDb);
}

double nowUs() {
    timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e6 + t.tv_nsec * 1e-3;
}

struct Stream {
    int format = kFormatS16;
    double scale = 32768.0;          /* full scale of the sample format */
    bool active = false;             /* the chain runs */
    double boostDb = 0.0;
    double boostGain = 1.0;          /* attenuation while inactive and boosted */
    unsigned sinceRefresh = 0;
    unsigned sinceGate = 0;
    gaokun::BassChain chain;
    gaokun::BassParams params;

    /* stats for the log line */
    unsigned statFrames = 0, statCalls = 0;
    double statPeakIn = 0.0, statPeakOut = 0.0, statUs = 0.0, statMaxUs = 0.0;

    void refresh(bool log) {
        boostDb = prop(kBoostProp, 0.0, 24.0, 0.0);
        boostGain = std::pow(10.0, -boostDb / 20.0);
        const bool want = wanted();
        const gaokun::BassParams p = readParams(boostDb);
        if (want != active) {
            active = want;
            params = p;
            chain.configure(p);
            chain.reset();
            logi("%s (boost %.0f dB)", active ? "processing" : "passthrough", boostDb);
            if (active) logParams("knobs", p, boostDb);
        } else if (active && !sameKnobs(p, params)) {
            params = p;
            chain.configure(p);
            logParams("knobs changed", p, boostDb);
        } else if (log && active) {
            logParams("knobs", p, boostDb);
        }
    }

    double read(const void *buf, size_t i) const {
        return format == kFormatS16 ? static_cast<const int16_t *>(buf)[i] / scale
                                    : static_cast<const int32_t *>(buf)[i] / scale;
    }

    void write(void *buf, size_t i, double v) const {
        const double s = std::nearbyint(v * scale);
        if (format == kFormatS16) {
            static_cast<int16_t *>(buf)[i] =
                    static_cast<int16_t>(s > 32767.0 ? 32767.0 : (s < -32768.0 ? -32768.0 : s));
        } else {
            static_cast<int32_t *>(buf)[i] = static_cast<int32_t>(
                    s > 2147483647.0 ? 2147483647.0 : (s < -2147483648.0 ? -2147483648.0 : s));
        }
    }

    void process(void *buf, size_t frames) {
        if (sinceRefresh == 0) {
            refresh(false);
        } else if (sinceGate == 0 && (wanted() != active ||
                                      prop(kBoostProp, 0.0, 24.0, 0.0) != boostDb)) {
            refresh(false);
        }
        sinceRefresh += static_cast<unsigned>(frames);
        sinceGate += static_cast<unsigned>(frames);
        if (sinceRefresh >= kRefreshFrames) sinceRefresh = 0;
        if (sinceGate >= kGateFrames) sinceGate = 0;

        if (!active) {
            if (boostDb > 0.0) {
                for (size_t i = 0; i < frames * 2; i++) write(buf, i, read(buf, i) * boostGain);
            }
            return;
        }

        const double t0 = nowUs();
        double pin = statPeakIn, pout = statPeakOut;
        for (size_t i = 0; i < frames; i++) {
            const double l = read(buf, 2 * i), r = read(buf, 2 * i + 1);
            double ol, orr;
            chain.step(l, r, ol, orr);
            write(buf, 2 * i, ol);
            write(buf, 2 * i + 1, orr);
            const double a = std::fmax(std::fabs(l), std::fabs(r));
            const double b = std::fmax(std::fabs(ol), std::fabs(orr));
            if (a > pin) pin = a;
            if (b > pout) pout = b;
        }
        const double us = nowUs() - t0;
        statPeakIn = pin;
        statPeakOut = pout;
        statUs += us;
        if (us > statMaxUs) statMaxUs = us;
        statCalls++;
        statFrames += static_cast<unsigned>(frames);
        if (statFrames >= kStatFrames) {
            const auto grDb = [](double g) { return -20.0 * std::log10(g > 1e-3 ? g : 1e-3); };
            logi("meter: peak in %.3f out %.3f, lc %+.1f dB, bass-gr %.1f dB, gr %.1f dB, "
                 "boost %.0f dB, ref %d, %.0f us/block avg %.0f max (%.1f%% of real time)",
                 statPeakIn, statPeakOut, chain.loudnessCompDb(), grDb(chain.minBassGain()),
                 grDb(chain.minFullGain()), boostDb, params.reference ? 1 : 0,
                 statUs / statCalls, statMaxUs, 100.0 * statUs / (statFrames / 48.0 * 1000.0));
            chain.resetStats();
            statFrames = statCalls = 0;
            statPeakIn = statPeakOut = statUs = statMaxUs = 0.0;
        }
    }
};

}  // namespace

extern "C" __attribute__((visibility("default"))) void *playback_hook_open(
        int card, int device, int sampleRate, int channelCount, int pcmFormat) {
    if (card != kSpeakerCard || device != kSpeakerDevice) return nullptr;
    if (sampleRate != 48000 || channelCount != 2 ||
        (pcmFormat != kFormatS16 && pcmFormat != kFormatS32)) {
        logi("speaker stream %d Hz, %d ch, format %d: not processed (48 kHz stereo S16/S32 only)",
             sampleRate, channelCount, pcmFormat);
        return nullptr;
    }
    Stream *s = new (std::nothrow) Stream();
    if (s == nullptr) return nullptr;
    s->format = pcmFormat;
    s->scale = pcmFormat == kFormatS16 ? 32768.0 : 2147483648.0;
    logi("speaker stream open: format %d", pcmFormat);
    s->refresh(true);
    s->sinceRefresh = 1;   /* just refreshed */
    return s;
}

extern "C" __attribute__((visibility("default"))) void playback_hook_process(void *handle,
                                                                             void *buffer,
                                                                             size_t frames) {
    if (handle == nullptr || buffer == nullptr || frames == 0) return;
    static_cast<Stream *>(handle)->process(buffer, frames);
}

extern "C" __attribute__((visibility("default"))) void playback_hook_close(void *handle) {
    if (handle == nullptr) return;
    logi("speaker stream close");
    delete static_cast<Stream *>(handle);
}
