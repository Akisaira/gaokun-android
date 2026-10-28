/*
 * bass_chain.h -- the speaker processing that runs in the audio HAL.
 *
 * WHY THIS EXISTS
 * ---------------
 * The two WSA8835 speakers give almost nothing below ~150 Hz and fall about
 * 12 dB per octave below ~500 Hz, but on their own they stay clean at full
 * scale down to 75 Hz.  This chain spends the headroom the current level
 * leaves on bass, without the bass ever pumping the rest of the mix.
 *
 * It runs on the speaker PCM in the audio HAL (speakerfx.cpp), after
 * AudioFlinger has mixed everything: music, games' FAST tracks, ringtones and
 * UI sounds all go through it, so its ceiling holds for every sound the
 * speakers play.
 *
 * THE CHAIN (48 kHz stereo only -- the fixed filters are designed for it)
 * ---------
 *   x -> LR4 split @ xoverHz
 *        high band -> low shelf shelfDb -------------------------+-> base
 *        low band, mono -> harmonics 2..4 (virtual bass) --------'
 *        high band, shelf dynTargetDb minus shelfDb ------------+
 *        low band, split @ lowHpHz:
 *          above, + lowBoostDb ----------------------------------+--> extra
 *          below, + lowSubDb ------------------------------------+
 *   base -> band-split dynamics -> crosstalk cancellation -> baseTrimDb
 *   out = (base + gb * extra) * gf, both gains from one look-ahead
 *
 * There is deliberately no fixed tone curve.  Huawei's Histen curves were
 * tried (scene 0, scene 3, and Windows' whole render chain measured by
 * loopback): each moved 3-5 kHz or the treble by 5-9 dB and each was worse
 * than none on these speakers -- harsh, sharp or muffled.  Scene 0 is not even
 * a tuning: its EQ band frequencies are a generic octave list (see
 * effects/README.md).
 *
 * Headroom.  base always plays.  extra -- the bass beyond the fixed shelf,
 * and the real band below the crossover -- gets the largest gain gb <= 1
 * that keeps base + gb * extra within the ceiling on both channels.  The
 * media volume is applied before the HAL, so at lower volumes extra plays in
 * full and at full volume it steps back.  gf is the full-band limiter, needed
 * only where base alone exceeds the ceiling.  Both gains look ahead by kLook
 * samples (a sliding minimum, then a moving average over kLook + 1), so the
 * needed gain is reached before the peak arrives and the output never exceeds
 * the ceiling; gb recovers linearly over bassReleaseMs, gf at releaseDbPerS.
 * baseTrimDb lowers base by a fixed amount to leave the extra group more room
 * -- fixed, so the voice never moves with the bass.
 *
 * Harmonics (virtual bass).  The analytic signal z = A e^{j phi} of the low
 * band comes from a 90-degree allpass network (bass_chain_coeffs.h);
 * harmonic n is Re(z^n) / E^(n-1), E = max(A, A followed with an envRelMs
 * release), so a note starting never overshoots.  z^n contains only sums of
 * the input frequencies: a bass note with its own overtones still yields only
 * its harmonics.  They fade in over onsetMs after an onset, so the first tens
 * of milliseconds of a kick -- its pitch sweeping down from 100-150 Hz -- do
 * not come out as a separate puff above the music.  The result is band-passed
 * to harmHpHz-harmLpHz, where the speakers do play.
 *
 * Sub-bass (lowHpHz, lowSubDb).  The speakers give nothing audible at
 * 30-45 Hz, but boosted sub-bass there still drives the cone through its
 * whole travel (break-up on a 35 Hz note at WSA digital volume 84 with the
 * band at +18 dB).  So the low band is split again at lowHpHz: above it gets
 * lowBoostDb, below only lowSubDb (or nothing, lowSubDb <= -60).  The high
 * band goes through the matching LR4 allpass, so the two still sum flat
 * around the crossover.
 *
 * Loudness compensation (lcSlope > 0).  The ear loses low frequencies faster
 * than the rest as the level drops (equal-loudness contours: 60 Hz needs about
 * 13 dB more relative to 1 kHz at 40 phon than at 80).  The chain sees the
 * signal after the media volume, so it tracks the program level -- mean power
 * of kLcBlock-sample input blocks, one-pole over lcTauS, blocks under lcGateDb
 * not counted -- and adds lcSlope dB of real-bass boost per dB the level is
 * under lcRefDb (at most lcMaxDb), lcShelfFrac of that to the shelf's dynamic
 * part.  The estimate follows the content, not the volume control: game mixes
 * run quieter than mastered music, which is why the slope is gentle.  Each
 * block uses the estimate from the end of the block before.  The first
 * kLcWarmBlocks blocks of sound after a start, or after more than
 * kLcQuietBlocks gated blocks, set the estimate to their own mean instead, so
 * it settles within 200 ms.  It is part of the headroom-gated group, so it
 * never adds clipping.
 *
 * Band-split dynamics (mbcOn).  base is split by an LR4 network at
 * mbcXover1/2 (the low band phase-compensated, so with every gain at 0 dB the
 * bands sum to an allpass).  Each band compares its short-term level (power
 * follower, attack mbcAttMs[band], release mbcRelMs, in dB) with its own
 * program level -- that reading averaged over mbcRefS -- and applies
 * -(1 - 1/ratio) times the difference, within [-cut, +boost].  Relative to the
 * program level, so the media volume still works; the slow attack lets the
 * first milliseconds of a hit through.  Nothing is raised while the program
 * level is under mbcGateDb.  For the first mbcWarmMs of sound after a start,
 * or after more than mbcQuietS under the gate, the program level follows the
 * short-term level, so a start is not pulled down for seconds.
 *
 * Crosstalk cancellation (xtcK > 0).  The side signal S = (L - R) / 2 of base
 * goes through the recursive canceller S / (1 - k * shadow * band * z^-D):
 * the shuffler form of XTC with the mid path left flat, so voice and bass are
 * untouched and only the image widens.  shadow is the spherical-head ratio
 * contralateral / ipsilateral (Brown-Duda, head radius 8.75 cm) for speakers
 * xtcSpanCm apart heard from xtcDistCm, D the interaural delay (Woodworth),
 * band a high-pass at xtcLoHz and a low-pass at xtcHiHz.  k < 1 regularises:
 * the side boost peaks at about 1 / (1 - k).  Most of the audible widening
 * comes from the side boost at 300-600 Hz, which is also where double-tracked
 * guitars live: raising xtcLoHz to 450-700 Hz keeps them clean and makes the
 * widening hard to hear.
 *
 * Reference mode (reference = true).  A passthrough at the voice-band gain of
 * the chain (makeupDb and baseTrimDb), still behind the limiter and with the
 * same latency, so an A/B comparison is not decided by loudness.
 *
 * NUMERICS AND FAILURE POLICY
 * ---------------------------
 * Everything runs in double precision: the low-band poles sit within 0.2 % of
 * z = 1.  configure() only computes coefficients and reset() only clears
 * state; neither allocates, and step() is bounded per frame (the look-ahead
 * minimum is a monotonic queue, the averages running sums), so all three are
 * safe on the audio thread.  The parameters are clamped by the caller
 * (speakerfx.cpp) before they get here.  Latency is kLook samples (3 ms).
 */
#ifndef GAOKUN_BASS_CHAIN_H
#define GAOKUN_BASS_CHAIN_H

#include <cmath>
#include <cstddef>

#include "bass_chain_coeffs.h"

namespace gaokun {

/* Defaults are what ships; speakerfx.cpp reads a subset from properties. */
struct BassParams {
    bool reference = false;      /* true: A/B reference, see above */
    double xoverHz = 150.0;
    double shelfDb = 8.0;        /* fixed upper-bass shelf, always there */
    double dynTargetDb = 12.0;   /* shelf the extra group tops up to */
    double shelfHz = 250.0;
    double lowBoostDb = 14.0;    /* the real band lowHpHz..xoverHz, in the extra group */
    double lowHpHz = 50.0;       /* where that band ends; 0 = it goes all the way down */
    double lowSubDb = 10.0;      /* the band under lowHpHz (<= -60: removed), extra group */
    double baseTrimDb = -3.0;    /* fixed trim of base, room for the extra group */
    double lcSlope = 0.15;       /* loudness compensation, dB per dB under lcRefDb */
    double lcRefDb = -15.0;
    double lcMaxDb = 12.0;
    double lcTauS = 4.0;
    double lcGateDb = -70.0;
    double lcShelfFrac = 0.5;
    double srcHpHz = 30.0;
    double weights[3] = {1.0, 0.4, 0.15};   /* harmonics 2, 3, 4 */
    double harmHpHz = 140.0;
    double harmLpHz = 500.0;
    double vbGainDb = -9.0;      /* <= -60: no harmonics */
    double envRelMs = 80.0;
    double onsetMs = 30.0;
    double makeupDb = 4.0;
    double ceilingDb = -1.0;
    double releaseDbPerS = 60.0;
    double bassReleaseMs = 150.0;
    bool mbcOn = true;
    double mbcRatio = 1.6;
    double mbcBoostDb = 4.0;
    double mbcCutDb = 4.0;
    double mbcXover1 = 500.0;
    double mbcXover2 = 4000.0;
    double mbcAttMs[3] = {25.0, 10.0, 10.0};
    double mbcRelMs = 150.0;
    double mbcRefS = 1.5;
    double mbcGateDb = -60.0;
    double mbcWarmMs = 200.0;
    double mbcQuietS = 1.0;
    double xtcK = 0.55;          /* 0: no crosstalk cancellation */
    double xtcSpanCm = 26.0;     /* distance between the two speakers */
    double xtcDistCm = 30.0;     /* listening distance */
    double xtcLoHz = 250.0;
    double xtcHiHz = 8000.0;
};

class BassChain {
  public:
    static constexpr double kFs = 48000.0;
    static constexpr int kLook = 144;            /* 3 ms; even, so the window is centred */
    static constexpr int kWin = kLook + 1;

    /* New coefficients; filter states and the look-ahead are kept, so a knob
     * moved during playback is heard as a change, not as a restart. */
    void configure(const BassParams &p) {
        mP = p;
        const double split = p.lowHpHz > 0.0 ? p.lowHpHz : 20.0;
        for (int ch = 0; ch < 2; ch++) {
            for (int s = 0; s < 2; s++) {
                mLo[ch][s].butter(p.xoverHz, false);
                mHi[ch][s].butter(p.xoverHz, true);
                mLowHp[ch][s].butter(split, true);
                mLowLp[ch][s].butter(split, false);
                mHiApLp[ch][s].butter(split, false);
                mHiApHp[ch][s].butter(split, true);
            }
            mShelf[ch].lowShelf(p.shelfDb, p.shelfHz);
            mFull[ch].lowShelf(p.dynTargetDb, p.shelfHz);
        }
        mSrcHp.butter(p.srcHpHz, true);
        for (int s = 0; s < 2; s++) mHarmHp[s].butter(p.harmHpHz, true);
        mHarmLp.butter(p.harmLpHz, false);
        mEnvAttFast = std::exp(-1.0 / (0.1e-3 * kFs));
        mEnvRel = std::exp(-1.0 / (p.envRelMs * 1e-3 * kFs));
        mEnvAttOnset = std::exp(-1.0 / (p.onsetMs * 1e-3 * kFs));
        mVbGain = p.vbGainDb > -60.0 ? std::pow(10.0, p.vbGainDb / 20.0) : 0.0;
        mMakeup = std::pow(10.0, p.makeupDb / 20.0);
        mLowBoost = std::pow(10.0, p.lowBoostDb / 20.0);
        mLowSub = p.lowSubDb > -60.0 ? std::pow(10.0, p.lowSubDb / 20.0) : 0.0;
        mLcA = std::exp(-kLcBlock / (p.lcTauS * kFs));
        if (p.lcSlope <= 0.0) {
            /* Off: no compensation left over from before. */
            mLcDb = 0.0;
            mLcSum = 0.0;
            mLcCount = 0;
        }
        mLcGate = std::pow(10.0, p.lcGateDb / 10.0);
        applyLc();
        mBaseTrim = std::pow(10.0, p.baseTrimDb / 20.0);
        mCeil = std::pow(10.0, p.ceilingDb / 20.0);
        mStepB = 1.0 / (p.bassReleaseMs * 1e-3 * kFs);
        mStepF = std::pow(10.0, p.releaseDbPerS / kFs / 20.0);
        configureXtc(p);
        configureMbc(p);
    }

    /* Start from silence: filter states, envelopes and the look-ahead. */
    void reset() {
        for (int ch = 0; ch < 2; ch++) {
            for (auto &b : mLo[ch]) b.clear();
            for (auto &b : mHi[ch]) b.clear();
            for (auto &b : mLowHp[ch]) b.clear();
            for (auto &b : mLowLp[ch]) b.clear();
            for (auto &b : mHiApLp[ch]) b.clear();
            for (auto &b : mHiApHp[ch]) b.clear();
            mShelf[ch].clear();
            mFull[ch].clear();
        }
        mSrcHp.clear();
        for (auto &b : mHarmHp) b.clear();
        mHarmLp.clear();
        for (int s = 0; s < bass_coeffs::kHilSections; s++) mApA[s] = mApB[s] = 0.0;
        mEnvFast = mEnvOnset = 0.0;
        for (int i = 0; i < kWin; i++) {
            mRB[i] = mRF[i] = 1.0;
            mBase[i][0] = mBase[i][1] = mExtra[i][0] = mExtra[i][1] = 0.0;
        }
        mMinB.clear();
        mMinF.clear();
        mSumB = mSumF = kWin;
        mFrame = 0;
        mRBPrev = mRFPrev = 1.0;
        mPos = 0;
        mLcEst = std::pow(10.0, mP.lcRefDb / 10.0);
        mLcSum = 0.0;
        mLcCount = 0;
        mLcDb = 0.0;
        mLcWarm = kLcWarmBlocks;
        mLcWarmSum = 0.0;
        mLcWarmN = 0;
        mLcQuiet = 0;
        applyLc();
        for (int ch = 0; ch < 2; ch++) {
            for (auto &band : mMbcF[ch]) for (auto &b : band) b.clear();
        }
        for (auto &b : mMbcBand) {
            b = MbcBand();
            b.warm = mMbcWarmN;
        }
        mXtcShadow.clear();
        mXtcHp.clear();
        mXtcLp.clear();
        for (double &v : mXtcRing) v = 0.0;
        mXtcPos = 0;
        resetStats();
    }

    /* One stereo frame; returns the frame kLook samples ago. */
    void step(double inL, double inR, double &outL, double &outR) {
        double base[2], extra[2];
        if (mP.reference) {
            base[0] = inL * mMakeup * mBaseTrim;
            base[1] = inR * mMakeup * mBaseTrim;
            extra[0] = extra[1] = 0.0;
        } else {
            double x[2] = {inL, inR};
            double lo[2], loX[2], loSub[2] = {0.0, 0.0}, fixed[2], full[2];
            for (int ch = 0; ch < 2; ch++) {
                const double v = x[ch];
                lo[ch] = mLo[ch][1].step(mLo[ch][0].step(v));
                double hi = mHi[ch][1].step(mHi[ch][0].step(v));
                loX[ch] = lo[ch];
                if (mP.lowHpHz > 0.0) {
                    loX[ch] = mLowHp[ch][1].step(mLowHp[ch][0].step(lo[ch]));
                    if (mLowSub > 0.0) loSub[ch] = mLowLp[ch][1].step(mLowLp[ch][0].step(lo[ch]));
                    hi = mHiApLp[ch][1].step(mHiApLp[ch][0].step(hi)) +
                         mHiApHp[ch][1].step(mHiApHp[ch][0].step(hi));
                }
                fixed[ch] = mShelf[ch].step(hi);
                full[ch] = mFull[ch].step(hi);
            }
            const double vb = mVbGain > 0.0 ? harmonics(0.5 * (lo[0] + lo[1])) * mVbGain : 0.0;
            for (int ch = 0; ch < 2; ch++) {
                base[ch] = (fixed[ch] + vb) * mMakeup;
                extra[ch] = (full[ch] - fixed[ch]) * mShelfLc * mMakeup + loX[ch] * mLowLc * mMakeup;
                if (mLowSub > 0.0) extra[ch] += loSub[ch] * mLowSub * mMakeup;
            }
            if (mP.mbcOn) mbc(base);
            if (mP.xtcK > 0.0) {
                const double m = 0.5 * (base[0] + base[1]);
                const double side = xtc(0.5 * (base[0] - base[1]));
                base[0] = m + side;
                base[1] = m - side;
            }
            base[0] *= mBaseTrim;
            base[1] *= mBaseTrim;
        }

        /* The block that ends with this frame sets the compensation for the
         * next block (this frame used the one from the block before). */
        if (mP.lcSlope > 0.0) {
            mLcSum += 0.5 * (inL * inL + inR * inR);
            if (++mLcCount == kLcBlock) {
                const double pw = mLcSum / kLcBlock;
                if (pw > mLcGate) {
                    mLcQuiet = 0;
                    if (mLcWarm > 0) {
                        mLcWarmSum += pw;
                        mLcEst = mLcWarmSum / ++mLcWarmN;
                        mLcWarm--;
                    } else {
                        mLcEst = mLcA * mLcEst + (1.0 - mLcA) * pw;
                    }
                } else if (++mLcQuiet > kLcQuietBlocks) {
                    mLcWarm = kLcWarmBlocks;
                    mLcWarmSum = 0.0;
                    mLcWarmN = 0;
                    mLcQuiet = kLcQuietBlocks;
                }
                double c = mP.lcSlope * (mP.lcRefDb - 10.0 * std::log10(mLcEst));
                mLcDb = c < 0.0 ? 0.0 : (c > mP.lcMaxDb ? mP.lcMaxDb : c);
                applyLc();
                mLcSum = 0.0;
                mLcCount = 0;
            }
        }

        /* Gains this frame could take: the bass group's largest gain that keeps
         * the sum within the ceiling on both channels, and the full-band gain
         * base alone needs. */
        double needB = 1.0;
        for (int ch = 0; ch < 2; ch++) {
            double lim = 1.0;
            if (extra[ch] > 0.0) lim = (mCeil - base[ch]) / extra[ch];
            else if (extra[ch] < 0.0) lim = (-mCeil - base[ch]) / extra[ch];
            if (lim < 0.0) lim = 0.0;
            if (lim < needB) needB = lim;
        }
        const double peak = std::fmax(std::fabs(base[0]), std::fabs(base[1]));
        const double needF = peak > mCeil ? mCeil / peak : 1.0;

        /* The ring holds the last kWin frames; mPos is where this one goes.
         * The oldest entry (mPos + 1) is the frame that leaves now. */
        mBase[mPos][0] = base[0];
        mBase[mPos][1] = base[1];
        mExtra[mPos][0] = extra[0];
        mExtra[mPos][1] = extra[1];

        /* Minimum over the window (the initial 1.0 entries never matter:
         * both needs are <= 1). */
        const double mB = mMinB.push(needB, mFrame);
        const double mF = mMinF.push(needF, mFrame);
        mFrame++;
        double rB = mRBPrev + mStepB;
        if (rB > 1.0) rB = 1.0;
        if (mB < rB) rB = mB;
        double rF = mRFPrev * mStepF;
        if (rF > 1.0) rF = 1.0;
        if (mF < rF) rF = mF;
        mRBPrev = rB;
        mRFPrev = rF;
        /* Running sums over the window; recomputed exactly once per lap so the
         * rounding never accumulates. */
        mSumB += rB - mRB[mPos];
        mSumF += rF - mRF[mPos];
        mRB[mPos] = rB;
        mRF[mPos] = rF;
        if (mPos == 0) {
            double sB = 0.0, sF = 0.0;
            for (int i = 0; i < kWin; i++) {
                sB += mRB[i];
                sF += mRF[i];
            }
            mSumB = sB;
            mSumF = sF;
        }
        const double gB = mSumB / kWin;
        const double gF = mSumF / kWin;
        if (gB < mMinGB) mMinGB = gB;
        if (gF < mMinGF) mMinGF = gF;

        const int old = (mPos + 1) % kWin;
        outL = (mBase[old][0] + gB * mExtra[old][0]) * gF;
        outR = (mBase[old][1] + gB * mExtra[old][1]) * gF;
        mPos = old;
    }

    /* ---- reporting, for the log --------------------------------------- */

    /* Current loudness compensation, dB. */
    double loudnessCompDb() const { return mLcDb; }
    /* Lowest gain the extra group (gb) and the full band (gf) got since the
     * last resetStats(), linear.  gb < 1 means the bass was held back by the
     * headroom; gf < 1 means base alone hit the ceiling. */
    double minBassGain() const { return mMinGB; }
    double minFullGain() const { return mMinGF; }
    void resetStats() { mMinGB = mMinGF = 1.0; }

  private:
    static constexpr int kXtcMaxDelay = 32;
    static constexpr int kLcBlock = 480;
    static constexpr int kLcWarmBlocks = 20;     /* 200 ms */
    static constexpr int kLcQuietBlocks = 100;   /* 1 s */

    void applyLc() {
        mLowLc = mLowBoost * std::pow(10.0, mLcDb / 20.0);
        mShelfLc = std::pow(10.0, mP.lcShelfFrac * mLcDb / 20.0);
    }

    /* Sliding minimum over the last kWin pushes: a monotonic queue, so each
     * frame costs O(1) on average instead of a scan of the window. */
    struct MinWindow {
        double v[kWin + 1];
        long long t[kWin + 1];
        int head = 0, size = 0;
        void clear() { head = size = 0; }
        double push(double x, long long now) {
            while (size > 0 && v[(head + size - 1) % (kWin + 1)] >= x) size--;
            const int at = (head + size) % (kWin + 1);
            v[at] = x;
            t[at] = now;
            size++;
            while (t[head] <= now - kWin) {
                head = (head + 1) % (kWin + 1);
                size--;
            }
            return v[head];
        }
    };

    /* Direct form II transposed, scipy's conventions (butter with prewarping). */
    struct Biquad {
        double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
        void clear() { z1 = z2 = 0.0; }
        double step(double x) {
            const double y = b0 * x + z1;
            z1 = b1 * x - a1 * y + z2;
            z2 = b2 * x - a2 * y;
            return y;
        }
        /* Second-order Butterworth, bilinear with prewarping (= scipy butter). */
        void butter(double fc, bool high) {
            const double k = std::tan(M_PI * fc / kFs);
            const double n = 1.0 / (1.0 + M_SQRT2 * k + k * k);
            if (high) {
                b0 = n; b1 = -2.0 * n; b2 = n;
            } else {
                b0 = k * k * n; b1 = 2.0 * b0; b2 = b0;
            }
            a1 = 2.0 * (k * k - 1.0) * n;
            a2 = (1.0 - M_SQRT2 * k + k * k) * n;
        }
        /* RBJ cookbook low shelf, slope 1. */
        void lowShelf(double gainDb, double f0) {
            const double A = std::pow(10.0, gainDb / 40.0);
            const double w = 2.0 * M_PI * f0 / kFs;
            const double al = std::sin(w) / 2.0 * M_SQRT2;
            const double c = std::cos(w);
            const double sa = 2.0 * std::sqrt(A) * al;
            const double a0 = (A + 1) + (A - 1) * c + sa;
            b0 = A * ((A + 1) - (A - 1) * c + sa) / a0;
            b1 = 2 * A * ((A - 1) - (A + 1) * c) / a0;
            b2 = A * ((A + 1) - (A - 1) * c - sa) / a0;
            a1 = -2 * ((A - 1) + (A + 1) * c) / a0;
            a2 = ((A + 1) + (A - 1) * c - sa) / a0;
        }
    };

    /* First-order section (b0 + b1 z^-1) / (1 + a1 z^-1), DF2T. */
    struct First {
        double b0 = 1, b1 = 0, a1 = 0, z1 = 0;
        void clear() { z1 = 0.0; }
        double step(double x) {
            const double y = b0 * x + z1;
            z1 = b1 * x - a1 * y;
            return y;
        }
    };

    /* Brown-Duda head shadow (alpha_min 0.1 at 150 degrees, head radius
     * 8.75 cm), Woodworth delay, bilinear without prewarping. */
    void configureXtc(const BassParams &p) {
        const double a = 0.0875, c = 343.0;
        const double theta = std::atan((p.xtcSpanCm / 2.0) / p.xtcDistCm);
        int d = static_cast<int>(std::lround(a / c * (theta + std::sin(theta)) * kFs));
        mXtcDelay = d < 1 ? 1 : (d > kXtcMaxDelay ? kXtcMaxDelay : d);
        auto alpha = [](double incDeg) {
            return 1.05 + 0.95 * std::cos(incDeg * M_PI / 180.0 * 180.0 / 150.0);
        };
        const double thetaDeg = theta * 180.0 / M_PI;
        const double ai = alpha(90.0 - thetaDeg), ac = alpha(90.0 + thetaDeg);
        const double w0 = 2.0 * c / a;
        const double kc = 2.0 * kFs * ac / w0, ki = 2.0 * kFs * ai / w0;
        mXtcShadow.b0 = (kc + 1.0) / (ki + 1.0);
        mXtcShadow.b1 = (1.0 - kc) / (ki + 1.0);
        mXtcShadow.a1 = (1.0 - ki) / (ki + 1.0);
        mXtcHp.butter(p.xtcLoHz, true);
        mXtcLp.butter(p.xtcHiHz, false);
    }

    /* S / (1 - k H z^-D): the loop filter H runs on the output, D samples
     * back through a ring. */
    double xtc(double s) {
        const int back = (mXtcPos - mXtcDelay + kXtcMaxDelay + 1) % (kXtcMaxDelay + 1);
        const double y = s + mP.xtcK * mXtcRing[back];
        mXtcRing[mXtcPos] = mXtcLp.step(mXtcHp.step(mXtcShadow.step(y)));
        mXtcPos = (mXtcPos + 1) % (kXtcMaxDelay + 1);
        return y;
    }

    /* Band-split dynamics state per band (shared by both channels). */
    struct MbcBand {
        double fast = 0.0, ref = 0.0, gain = 0.0;
        bool started = false;
        int warm = 0, quiet = 0;
    };

    void configureMbc(const BassParams &p) {
        for (int ch = 0; ch < 2; ch++) {
            for (int k = 0; k < 2; k++) {
                mMbcF[ch][0][k].butter(p.mbcXover1, false);   /* low = LR4 LP f1 */
                mMbcF[ch][1][k].butter(p.mbcXover1, true);    /* rest = LR4 HP f1 */
                mMbcF[ch][2][k].butter(p.mbcXover2, false);   /* mid = LR4 LP f2 of rest */
                mMbcF[ch][3][k].butter(p.mbcXover2, true);    /* high = LR4 HP f2 of rest */
                mMbcF[ch][4][k].butter(p.mbcXover2, false);   /* low through the f2 allpass */
                mMbcF[ch][5][k].butter(p.mbcXover2, true);
            }
        }
        mMbcK = 1.0 - 1.0 / p.mbcRatio;
        for (int b = 0; b < 3; b++) mMbcAtt[b] = std::exp(-1.0 / (p.mbcAttMs[b] * 1e-3 * kFs));
        mMbcRel = std::exp(-1.0 / (p.mbcRelMs * 1e-3 * kFs));
        mMbcRefA = std::exp(-1.0 / (p.mbcRefS * kFs));
        mMbcSm = std::exp(-1.0 / (0.005 * kFs));
        mMbcWarmN = static_cast<int>(p.mbcWarmMs * 1e-3 * kFs);
        mMbcQuietN = static_cast<int>(p.mbcQuietS * kFs);
    }

    static double lr4(Biquad (&f)[2], double x) { return f[1].step(f[0].step(x)); }

    void mbc(double (&x)[2]) {
        double band[3][2];
        for (int ch = 0; ch < 2; ch++) {
            auto &f = mMbcF[ch];
            const double lo = lr4(f[0], x[ch]);
            const double rest = lr4(f[1], x[ch]);
            band[1][ch] = lr4(f[2], rest);
            band[2][ch] = lr4(f[3], rest);
            band[0][ch] = lr4(f[4], lo) + lr4(f[5], lo);
        }
        double y[2] = {0.0, 0.0};
        for (int b = 0; b < 3; b++) {
            MbcBand &s = mMbcBand[b];
            const double pw = 0.5 * (band[b][0] * band[b][0] + band[b][1] * band[b][1]);
            follow(pw, s.fast, mMbcAtt[b], mMbcRel);
            const double lf = 10.0 * std::log10(s.fast > 1e-12 ? s.fast : 1e-12);
            if (!s.started) {
                s.ref = lf;
                s.started = true;
            }
            if (lf < mP.mbcGateDb) {
                if (s.quiet <= mMbcQuietN && ++s.quiet > mMbcQuietN) s.warm = mMbcWarmN;
            } else {
                s.quiet = 0;
            }
            if (s.warm > 0 && lf >= mP.mbcGateDb) {
                s.ref = lf;
                s.warm--;
            } else {
                s.ref = mMbcRefA * s.ref + (1.0 - mMbcRefA) * lf;
            }
            double g = -mMbcK * (lf - s.ref);
            if (g < -mP.mbcCutDb) g = -mP.mbcCutDb;
            if (g > mP.mbcBoostDb) g = mP.mbcBoostDb;
            if (g > 0.0 && s.ref < mP.mbcGateDb) g = 0.0;
            s.gain = (1.0 - mMbcSm) * g + mMbcSm * s.gain;
            const double lin = std::pow(10.0, s.gain / 20.0);
            y[0] += band[b][0] * lin;
            y[1] += band[b][1] * lin;
        }
        x[0] = y[0];
        x[1] = y[1];
    }

    static double follow(double v, double &s, double att, double rel) {
        const double g = v > s ? att : rel;
        s = g * s + (1.0 - g) * v;
        return s;
    }

    double harmonics(double lo) {
        const double src = mSrcHp.step(lo);
        double i = src, q = src;
        for (int s = 0; s < bass_coeffs::kHilSections; s++) {
            const double ca = bass_coeffs::kHilA[s];
            const double yi = ca * i + mApA[s];
            mApA[s] = i - ca * yi;
            i = yi;
            const double cb = bass_coeffs::kHilB[s];
            const double yq = cb * q + mApB[s];
            mApB[s] = q - cb * yq;
            q = yq;
        }
        const double a = std::sqrt(i * i + q * q);
        double e = follow(a, mEnvFast, mEnvAttFast, mEnvRel);
        if (a > e) e = a;
        if (e < 1e-6) e = 1e-6;
        /* z^2, z^3, z^4 over E, E^2, E^3 */
        double zr = i * i - q * q, zi = 2.0 * i * q;
        double y = mP.weights[0] * zr / e;
        double nr = zr * i - zi * q, ni = zr * q + zi * i;
        y += mP.weights[1] * nr / (e * e);
        zr = nr * i - ni * q;
        y += mP.weights[2] * zr / (e * e * e);
        const double onset = follow(a, mEnvOnset, mEnvAttOnset, mEnvRel) / e;
        if (onset < 1.0) y *= onset;
        y = mHarmHp[1].step(mHarmHp[0].step(y));
        return mHarmLp.step(y);
    }

    BassParams mP;
    Biquad mLo[2][2], mHi[2][2], mShelf[2], mFull[2];
    Biquad mLowHp[2][2], mLowLp[2][2], mHiApLp[2][2], mHiApHp[2][2];
    Biquad mSrcHp, mHarmHp[2], mHarmLp;
    double mApA[bass_coeffs::kHilSections] = {}, mApB[bass_coeffs::kHilSections] = {};
    double mEnvFast = 0.0, mEnvOnset = 0.0;
    double mEnvAttFast = 0.0, mEnvRel = 0.0, mEnvAttOnset = 0.0;
    double mVbGain = 0.0, mMakeup = 1.0, mCeil = 1.0, mStepB = 0.0, mStepF = 1.0;
    double mLowBoost = 1.0, mLowSub = 0.0, mBaseTrim = 1.0;
    double mLcA = 0.0, mLcGate = 0.0, mLcEst = 1.0, mLcSum = 0.0, mLcDb = 0.0;
    double mLowLc = 1.0, mShelfLc = 1.0;
    int mLcCount = 0;
    int mLcWarm = 0, mLcWarmN = 0, mLcQuiet = 0;
    double mLcWarmSum = 0.0;

    MinWindow mMinB, mMinF;
    long long mFrame = 0;
    double mRB[kWin] = {}, mRF[kWin] = {};
    double mSumB = kWin, mSumF = kWin;
    double mBase[kWin][2] = {}, mExtra[kWin][2] = {};
    double mRBPrev = 1.0, mRFPrev = 1.0;
    int mPos = 0;
    double mMinGB = 1.0, mMinGF = 1.0;

    Biquad mMbcF[2][6][2];
    MbcBand mMbcBand[3];
    double mMbcK = 0.0, mMbcAtt[3] = {}, mMbcRel = 0.0, mMbcRefA = 0.0, mMbcSm = 0.0;
    int mMbcWarmN = 0, mMbcQuietN = 0;

    First mXtcShadow;
    Biquad mXtcHp, mXtcLp;
    double mXtcRing[kXtcMaxDelay + 1] = {};
    int mXtcPos = 0, mXtcDelay = 1;
};

}  // namespace gaokun

#endif  // GAOKUN_BASS_CHAIN_H
