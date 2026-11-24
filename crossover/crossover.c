#include <stdint.h>
#include <stddef.h>
#include <math.h>

#define PI 3.14159265358979323846

typedef struct {
    double b0, b1, b2, a1, a2;
    double z1, z2;
} Biquad;

typedef struct {
    Biquad lp[2][2], hp[2][2];
    double woofer_gain, tweeter_gain;
    double tweeter_target_gain, tweeter_gain_step;
    unsigned long tweeter_ramp_remaining;
} Crossover;

static void init_biquad(Biquad *b, double fs, double frequency,
                        int highpass)
{
    double w = 2.0 * PI * frequency / fs;
    double c = cos(w), s = sin(w);
    double alpha = s / (2.0 * 0.7071067811865476);
    double a0 = 1.0 + alpha;

    if (highpass) {
        b->b0 = (1.0 + c) / 2.0 / a0;
        b->b1 = -(1.0 + c) / a0;
        b->b2 = b->b0;
    } else {
        b->b0 = (1.0 - c) / 2.0 / a0;
        b->b1 = (1.0 - c) / a0;
        b->b2 = b->b0;
    }

    b->a1 = -2.0 * c / a0;
    b->a2 = (1.0 - alpha) / a0;
    b->z1 = b->z2 = 0.0;
}

static double process_biquad(Biquad *b, double x)
{
    double y = b->b0 * x + b->z1;
    b->z1 = b->b1 * x - b->a1 * y + b->z2;
    b->z2 = b->b2 * x - b->a2 * y;
    return y;
}

void crossover_init(Crossover *c, double sample_rate,
                    double crossover_frequency)
{
    for (int i = 0; i < 2; i++) {
        for (int ch = 0; ch < 2; ch++)
            init_biquad(&c->lp[i][ch], sample_rate, crossover_frequency, 0);
        for (int ch = 0; ch < 2; ch++)
            init_biquad(&c->hp[i][ch], sample_rate, crossover_frequency, 1);
    }

    c->woofer_gain = 1.0;
    c->tweeter_gain = 1.0;
    c->tweeter_target_gain = 1.0;
    c->tweeter_gain_step = 0.0;
    c->tweeter_ramp_remaining = 0;
}

void crossover_set_tweeter_gain_db(Crossover *c, double db,
                                    double sample_rate)
{
    double target = pow(10.0, db / 20.0);
    unsigned long ramp_frames = (unsigned long)(sample_rate * 0.050);

    c->tweeter_target_gain = target;
    c->tweeter_ramp_remaining = ramp_frames;

    if (ramp_frames == 0) {
        c->tweeter_gain = target;
        c->tweeter_gain_step = 0.0;
    } else {
        c->tweeter_gain_step =
            (target - c->tweeter_gain) / (double)ramp_frames;
    }
}

static int32_t to_s32(double x)
{
    if (x > 2147483647.0) x = 2147483647.0;
    if (x < -2147483648.0) x = -2147483648.0;
    return (int32_t)x;
}

/* Input: stereo interleaved. Output: woofer L/R, tweeter L/R. */
void crossover_process(Crossover *c, const int32_t *in,
                       int32_t *out, size_t frames)
{
    for (size_t i = 0; i < frames; i++) {
        if (c->tweeter_ramp_remaining > 0) {
            c->tweeter_gain += c->tweeter_gain_step;
            c->tweeter_ramp_remaining--;

            if (c->tweeter_ramp_remaining == 0)
                c->tweeter_gain = c->tweeter_target_gain;
        }

        for (int ch = 0; ch < 2; ch++) {
            double x = (double)in[2 * i + ch];

            double lo = process_biquad(&c->lp[1][ch],
                         process_biquad(&c->lp[0][ch], x));
            double hi = process_biquad(&c->hp[1][ch],
                         process_biquad(&c->hp[0][ch], x));

            out[4 * i + ch] = to_s32(lo * c->woofer_gain);
            out[4 * i + 2 + ch] = to_s32(hi * c->tweeter_gain);
        }
    }
}
