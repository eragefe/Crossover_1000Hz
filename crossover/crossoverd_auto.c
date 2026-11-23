#include <alsa/asoundlib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

#include "crossover.c"

#define PERIOD 256
#define BUFFER (PERIOD * 4)

static volatile sig_atomic_t running = 1;

static void stop_handler(int sig)
{
    (void)sig;
    running = 0;
}

static int get_stream_config(unsigned int *rate, snd_pcm_format_t *format)
{
    int card = snd_card_get_index("Loopback");
    if (card < 0) return 0;

    char path[128];
    snprintf(path, sizeof(path),
             "/proc/asound/card%d/pcm0p/sub0/hw_params", card);

    FILE *f = fopen(path, "r");
    if (!f) return 0;

    char line[128], fmt[32] = "";
    unsigned int r = 0;

    while (fgets(line, sizeof(line), f)) {
        sscanf(line, "rate: %u", &r);
        sscanf(line, "format: %31s", fmt);
    }
    fclose(f);

    if (!r) return 0;

    if (!strcmp(fmt, "S16_LE"))
        *format = SND_PCM_FORMAT_S16_LE;
    else if (!strcmp(fmt, "S24_3LE"))
        *format = SND_PCM_FORMAT_S24_3LE;
    else if (!strcmp(fmt, "S32_LE"))
        *format = SND_PCM_FORMAT_S32_LE;
    else {
        fprintf(stderr, "Unsupported input format: %s\n", fmt);
        return 0;
    }

    *rate = r;
    return 1;
}

static int configure_pcm(snd_pcm_t *pcm, unsigned int channels,
                         unsigned int rate, snd_pcm_format_t format)
{
    snd_pcm_hw_params_t *hw;
    snd_pcm_hw_params_alloca(&hw);

    int err = snd_pcm_hw_params_any(pcm, hw);
    if (err < 0) return err;

    if ((err = snd_pcm_hw_params_set_access(
             pcm, hw, SND_PCM_ACCESS_RW_INTERLEAVED)) < 0) return err;

    if ((err = snd_pcm_hw_params_set_format(pcm, hw, format)) < 0)
        return err;

    if ((err = snd_pcm_hw_params_set_channels(
             pcm, hw, channels)) < 0) return err;

    if ((err = snd_pcm_hw_params_set_rate(
             pcm, hw, rate, 0)) < 0) return err;

    snd_pcm_uframes_t period = PERIOD;
    snd_pcm_uframes_t buffer = BUFFER;

    if ((err = snd_pcm_hw_params_set_period_size_near(
             pcm, hw, &period, NULL)) < 0) return err;

    if ((err = snd_pcm_hw_params_set_buffer_size_near(
             pcm, hw, &buffer)) < 0) return err;

    return snd_pcm_hw_params(pcm, hw);
}

static void close_devices(snd_pcm_t *in, snd_pcm_t *out)
{
    if (in) {
        snd_pcm_drop(in);
        snd_pcm_close(in);
    }
    if (out) {
        snd_pcm_drop(out);
        snd_pcm_close(out);
    }
}

static void convert_input(const uint8_t *raw, int32_t *input,
                          size_t samples, snd_pcm_format_t format)
{
    if (format == SND_PCM_FORMAT_S32_LE) {
        memcpy(input, raw, samples * sizeof(int32_t));
        return;
    }

    if (format == SND_PCM_FORMAT_S16_LE) {
        for (size_t i = 0; i < samples; i++) {
            int16_t v;
            memcpy(&v, raw + 2 * i, sizeof(v));
            input[i] = (int32_t)v * 65536;
        }
        return;
    }

    if (format == SND_PCM_FORMAT_S24_3LE) {
        for (size_t i = 0; i < samples; i++) {
            int32_t v = (int32_t)raw[3*i]
                      | ((int32_t)raw[3*i+1] << 8)
                      | ((int32_t)raw[3*i+2] << 16);

            if (v & 0x800000)
                v |= (int32_t)0xff000000;

            input[i] = v * 256;
        }
    }
}

int main(void)
{
    signal(SIGINT, stop_handler);
    signal(SIGTERM, stop_handler);

    uint8_t raw[PERIOD * 2 * 4];
    int32_t input[PERIOD * 2];
    int32_t output[PERIOD * 4];

    fprintf(stderr, "Crossover waiting for loopback playback...\n");

    while (running) {
        unsigned int rate;
        snd_pcm_format_t format;

        if (!get_stream_config(&rate, &format)) {
            usleep(20000);
            continue;
        }

        snd_pcm_t *in = NULL;
        snd_pcm_t *out = NULL;

        int err = snd_pcm_open(&in, "hw:Loopback,1,0",
                               SND_PCM_STREAM_CAPTURE, SND_PCM_NONBLOCK);
        if (err < 0) {
            fprintf(stderr, "Cannot open capture: %s\n", snd_strerror(err));
            usleep(200000);
            continue;
        }

        err = configure_pcm(in, 2, rate, format);
        if (err < 0) {
            fprintf(stderr, "Cannot configure capture at %u Hz (%s): %s\n",
                    rate, snd_pcm_format_name(format), snd_strerror(err));
            close_devices(in, NULL);
            usleep(200000);
            continue;
        }

        err = snd_pcm_open(&out, "hw:DAC,0", SND_PCM_STREAM_PLAYBACK, 0);
        if (err < 0) {
            fprintf(stderr, "Cannot open DAC: %s\n", snd_strerror(err));
            close_devices(in, NULL);
            usleep(200000);
            continue;
        }

        err = configure_pcm(out, 4, rate, SND_PCM_FORMAT_S32_LE);
        if (err < 0) {
            fprintf(stderr, "Cannot configure DAC at %u Hz: %s\n",
                    rate, snd_strerror(err));
            close_devices(in, out);
            usleep(200000);
            continue;
        }

        Crossover dsp;
        crossover_init(&dsp, rate);

        fprintf(stderr, "Crossover running: %u Hz, input %s, output S32_LE\n",
                rate, snd_pcm_format_name(format));

        while (running) {
            unsigned int current_rate;
            snd_pcm_format_t current_format;

            if (!get_stream_config(&current_rate, &current_format) ||
                current_rate != rate || current_format != format)
                break;

            snd_pcm_sframes_t n = snd_pcm_readi(in, raw, PERIOD);

            if (n == -EAGAIN) {
                usleep(1000);
                continue;
            }

            if (n < 0) {
                err = snd_pcm_recover(in, (int)n, 1);
                if (err < 0) {
                    fprintf(stderr, "Capture error: %s\n", snd_strerror(err));
                    break;
                }
                continue;
            }

            if (n == 0) continue;

            convert_input(raw, input, (size_t)n * 2, format);
            crossover_process(&dsp, input, output, (size_t)n);

            snd_pcm_sframes_t sent = 0;

            while (sent < n && running) {
                snd_pcm_sframes_t written =
                    snd_pcm_writei(out, output + 4 * sent, n - sent);

                if (written < 0) {
                    err = snd_pcm_recover(out, (int)written, 1);
                    if (err < 0) {
                        fprintf(stderr, "Playback error: %s\n",
                                snd_strerror(err));
                        running = 0;
                        break;
                    }
                    continue;
                }

                sent += written;
            }
        }

        close_devices(in, out);
        fprintf(stderr, "Stream ended; waiting for next stream.\n");
    }

    fprintf(stderr, "Crossover stopped.\n");
    return 0;
}
