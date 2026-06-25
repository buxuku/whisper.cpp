#include "napi.h"
#include "common.h"
#include "common-whisper.h"

#include "whisper.h"

#include <atomic>
#include <memory>
#include <string>
#include <thread>
#include <vector>
#include <cmath>
#include <cstdint>
#include <cfloat>

struct whisper_params {
    int32_t n_threads    = std::min(4, (int32_t) std::thread::hardware_concurrency());
    int32_t n_processors = 1;
    int32_t offset_t_ms  = 0;
    int32_t offset_n     = 0;
    int32_t duration_ms  = 0;
    int32_t max_context  = -1;
    int32_t max_len      = 0;
    int32_t best_of      = 5;
    int32_t beam_size    = -1;
    int32_t audio_ctx    = 0;

    float word_thold    = 0.01f;
    float entropy_thold = 2.4f;
    float logprob_thold = -1.0f;

    bool translate      = false;
    bool diarize        = false;
    bool output_txt     = false;
    bool output_vtt     = false;
    bool output_srt     = false;
    bool output_wts     = false;
    bool output_csv     = false;
    bool print_special  = false;
    bool print_colors   = false;
    bool print_progress = false;
    bool no_timestamps  = false;
    bool no_prints      = false;
    bool detect_language= false;
    bool use_gpu        = true;
    bool flash_attn     = false;
    bool comma_in_time  = true;

    std::string language = "en";
    std::string prompt;
    std::string model    = "../../ggml-large.bin";

    std::vector<std::string> fname_inp = {};
    std::vector<std::string> fname_out = {};

    std::vector<float> pcmf32 = {}; // mono-channel F32 PCM

    // Voice Activity Detection (VAD) parameters
    bool        vad           = false;
    std::string vad_model     = "";
    float       vad_threshold = 0.5f;
    int         vad_min_speech_duration_ms = 250;
    int         vad_min_silence_duration_ms = 100;
    float       vad_max_speech_duration_s = FLT_MAX;
    int         vad_speech_pad_ms = 30;
    float       vad_samples_overlap = 0.1f;

    // [addon] VAD timeline alignment (faster-whisper-like).
    // When VAD is enabled, instead of letting whisper.cpp concatenate all speech
    // into one continuous stream (which yields a gap-less timeline where every
    // segment end == next segment start), we detect speech regions ourselves,
    // group adjacent VAD segments into "runs" and transcribe each run from its own
    // sliced audio buffer, so the returned timestamps land on the original timeline
    // with real gaps during silence.
    //   >= 0 : adjacent VAD segments whose silence gap is <= this value (ms) are
    //          merged into one run; a larger gap starts a new run (a real subtitle
    //          gap). Because each run is decoded independently, larger values keep
    //          more context together (better text, fewer cuts) while still breaking
    //          on real pauses; smaller values produce more, shorter gaps but can cut
    //          mid-sentence and hurt quality. Default 2000ms.
    //   <  0 : disable per-run alignment and fall back to the legacy single-call
    //          core-VAD path (continuous timeline).
    int         vad_merge_gap_ms = 2000;

    // [addon] Timeline alignment strategy:
    //   "hybrid" (default) Approach C: VAD-grouped runs (like "run") but each run is
    //            additionally re-segmented by word-level gaps and every segment end is
    //            clamped to its last word. Combines VAD robustness (no hallucination in
    //            silence, gaps between runs) with faster-whisper-like word-level cuts.
    //   "run"    Approach A: detect speech with VAD, group adjacent segments into runs
    //            (vad_merge_gap_ms) and transcribe each run from its own sliced buffer,
    //            emitting whisper's own segments. Gaps appear between runs.
    //   "word"   Approach B (faster-whisper-like): a single decode pass over the whole
    //            audio with token-level timestamps, then re-segment wherever the silence
    //            between consecutive words exceeds word_gap_ms and clamp every segment
    //            end to its last word. When a VAD model is provided core VAD is enabled
    //            for this pass (it removes silence so the decoder won't hallucinate in
    //            it); word times are read through whisper_full_get_token_t0/t1, which map
    //            them back onto the original timeline. Without a VAD model it is a plain
    //            single pass and token times are already on the timeline.
    //   "legacy" single pass, continuous timeline (original behavior).
    // "hybrid"/"run" fall back to "word"/"legacy" respectively if VAD is unavailable.
    std::string align_mode  = "hybrid";
    // For "word"/"hybrid": start a new segment when the gap between two consecutive
    // words is larger than this (ms). Smaller => more, tighter cuts. Default 500ms.
    int         word_gap_ms = 500;
};

struct whisper_print_user_data {
    const whisper_params * params;

    const std::vector<std::vector<float>> * pcmf32s;
};

void whisper_print_segment_callback(struct whisper_context * ctx, struct whisper_state * state, int n_new, void * user_data) {
    const auto & params  = *((whisper_print_user_data *) user_data)->params;
    const auto & pcmf32s = *((whisper_print_user_data *) user_data)->pcmf32s;

    const int n_segments = whisper_full_n_segments(ctx);

    std::string speaker = "";

    int64_t t0;
    int64_t t1;

    // print the last n_new segments
    const int s0 = n_segments - n_new;

    if (s0 == 0) {
        printf("\n");
    }

    for (int i = s0; i < n_segments; i++) {
        if (!params.no_timestamps || params.diarize) {
            t0 = whisper_full_get_segment_t0(ctx, i);
            t1 = whisper_full_get_segment_t1(ctx, i);
        }

        if (!params.no_timestamps && !params.no_prints) {
            printf("[%s --> %s]  ", to_timestamp(t0).c_str(), to_timestamp(t1).c_str());
        }

        if (params.diarize && pcmf32s.size() == 2) {
            const int64_t n_samples = pcmf32s[0].size();

            const int64_t is0 = timestamp_to_sample(t0, n_samples, WHISPER_SAMPLE_RATE);
            const int64_t is1 = timestamp_to_sample(t1, n_samples, WHISPER_SAMPLE_RATE);

            double energy0 = 0.0f;
            double energy1 = 0.0f;

            for (int64_t j = is0; j < is1; j++) {
                energy0 += fabs(pcmf32s[0][j]);
                energy1 += fabs(pcmf32s[1][j]);
            }

            if (energy0 > 1.1*energy1) {
                speaker = "(speaker 0)";
            } else if (energy1 > 1.1*energy0) {
                speaker = "(speaker 1)";
            } else {
                speaker = "(speaker ?)";
            }

            //printf("is0 = %lld, is1 = %lld, energy0 = %f, energy1 = %f, %s\n", is0, is1, energy0, energy1, speaker.c_str());
        }

        // colorful print bug
        //
        if (!params.no_prints) {
            const char * text = whisper_full_get_segment_text(ctx, i);
            printf("%s%s", speaker.c_str(), text);
        }


        // with timestamps or speakers: each segment on new line
        if ((!params.no_timestamps || params.diarize) && !params.no_prints) {
            printf("\n");
        }

        fflush(stdout);
    }
}

void cb_log_disable(enum ggml_log_level, const char *, void *) {}

struct whisper_result {
    std::vector<std::vector<std::string>> segments;
    std::string language;
};

class ProgressWorker : public Napi::AsyncWorker {
 public:
    ProgressWorker(Napi::Function& callback, whisper_params params, Napi::Function progress_callback, Napi::Env env,
                   std::shared_ptr<std::atomic<bool>> is_aborted)
        : Napi::AsyncWorker(callback), params(params), env(env), is_aborted(std::move(is_aborted)) {
        // Create thread-safe function
        if (!progress_callback.IsEmpty()) {
            tsfn = Napi::ThreadSafeFunction::New(
                env,
                progress_callback,
                "Progress Callback",
                0,
                1
            );
        }
    }

    ~ProgressWorker() {
        if (tsfn) {
            // Make sure to release the thread-safe function on destruction
            tsfn.Release();
        }
    }

    void Execute() override {
        // Use custom run function with progress callback support
        run_with_progress(params, result);
    }

    void OnOK() override {
        Napi::HandleScope scope(Env());

        if (params.detect_language) {
            Napi::Object resultObj = Napi::Object::New(Env());
            resultObj.Set("language", Napi::String::New(Env(), result.language));
            Callback().Call({Env().Null(), resultObj});
        }

        Napi::Object returnObj = Napi::Object::New(Env());
        returnObj.Set("cancelled", Napi::Boolean::New(Env(), is_aborted->load()));
        if (!result.language.empty()) {
            returnObj.Set("language", Napi::String::New(Env(), result.language));
        }
        Napi::Array transcriptionArray = Napi::Array::New(Env(), result.segments.size());
        for (uint64_t i = 0; i < result.segments.size(); ++i) {
            Napi::Object tmp = Napi::Array::New(Env(), 3);
            for (uint64_t j = 0; j < 3; ++j) {
                tmp[j] = Napi::String::New(Env(), result.segments[i][j]);
            }
            transcriptionArray[i] = tmp;
         }
         returnObj.Set("transcription", transcriptionArray);
         Callback().Call({Env().Null(), returnObj});
    }

    // Progress callback function - using thread-safe function
    void OnProgress(int progress) {
        if (tsfn) {
            // When transcribing per VAD run, map the per-run 0..100 onto the
            // overall timeline (weighted by each run's duration) so the JS side
            // sees a single monotonic 0..100 instead of restarting every run.
            int overall = progress;
            if (prog_total_ms > 0.0) {
                double v = (prog_done_ms + (progress / 100.0) * prog_cur_ms) / prog_total_ms * 100.0;
                if (v < 0.0)   v = 0.0;
                if (v > 100.0) v = 100.0;
                overall = (int) (v + 0.5);
            }
            // Use thread-safe function to call JavaScript callback
            auto callback = [overall](Napi::Env env, Napi::Function jsCallback) {
                jsCallback.Call({Napi::Number::New(env, overall)});
            };

            tsfn.BlockingCall(callback);
        }
    }

 private:
    whisper_params params;
    whisper_result result;
    Napi::Env env;
    Napi::ThreadSafeFunction tsfn;
    std::shared_ptr<std::atomic<bool>> is_aborted;
    // Progress scaling across multiple whisper_full calls (VAD per-run path).
    // prog_total_ms == 0 means "pass the raw 0..100 progress through unchanged".
    double prog_total_ms = 0.0; // total speech ms to transcribe across all runs
    double prog_done_ms  = 0.0; // ms fully completed before the current run
    double prog_cur_ms   = 0.0; // duration (ms) of the run currently in progress

    // Custom run function with progress callback support
    int run_with_progress(whisper_params &params, whisper_result & result) {
        if (params.no_prints) {
            whisper_log_set(cb_log_disable, NULL);
        }

        if (params.fname_inp.empty() && params.pcmf32.empty()) {
            fprintf(stderr, "error: no input files or audio buffer specified\n");
            return 2;
        }

        if (params.language != "auto" && whisper_lang_id(params.language.c_str()) == -1) {
            fprintf(stderr, "error: unknown language '%s'\n", params.language.c_str());
            exit(0);
        }

        // whisper init
        struct whisper_context_params cparams = whisper_context_default_params();
        cparams.use_gpu = params.use_gpu;
        cparams.flash_attn = params.flash_attn;
        struct whisper_context * ctx = whisper_init_from_file_with_params(params.model.c_str(), cparams);

        if (ctx == nullptr) {
            fprintf(stderr, "error: failed to initialize whisper context\n");
            return 3;
        }

        // If params.pcmf32 provides, set params.fname_inp as "buffer"
        if (!params.pcmf32.empty()) {
            fprintf(stderr, "info: using audio buffer as input\n");
            params.fname_inp.clear();
            params.fname_inp.emplace_back("buffer");
        }

        for (int f = 0; f < (int) params.fname_inp.size(); ++f) {
            const auto fname_inp = params.fname_inp[f];
            const auto fname_out = f < (int)params.fname_out.size() && !params.fname_out[f].empty() ? params.fname_out[f] : params.fname_inp[f];

            std::vector<float> pcmf32; // mono-channel F32 PCM
            std::vector<std::vector<float>> pcmf32s; // stereo-channel F32 PCM

            // If params.pcmf32 is empty, read input audio file
            if (params.pcmf32.empty()) {
                if (!::read_audio_data(fname_inp, pcmf32, pcmf32s, params.diarize)) {
                    fprintf(stderr, "error: failed to read audio file '%s'\n", fname_inp.c_str());
                    continue;
                }
            } else {
                pcmf32 = params.pcmf32;
            }

            // Print system info
            if (!params.no_prints) {
                fprintf(stderr, "\n");
                fprintf(stderr, "system_info: n_threads = %d / %d | %s\n",
                        params.n_threads*params.n_processors, std::thread::hardware_concurrency(), whisper_print_system_info());
            }

            // Print processing info
            if (!params.no_prints) {
                fprintf(stderr, "\n");
                if (!whisper_is_multilingual(ctx)) {
                    if (params.language != "en" || params.translate) {
                        params.language = "en";
                        params.translate = false;
                        fprintf(stderr, "%s: WARNING: model is not multilingual, ignoring language and translation options\n", __func__);
                    }
                }
                fprintf(stderr, "%s: processing '%s' (%d samples, %.1f sec), %d threads, %d processors, lang = %s, task = %s, timestamps = %d, audio_ctx = %d ...\n",
                        __func__, fname_inp.c_str(), int(pcmf32.size()), float(pcmf32.size())/WHISPER_SAMPLE_RATE,
                        params.n_threads, params.n_processors,
                        params.language.c_str(),
                        params.translate ? "translate" : "transcribe",
                        params.no_timestamps ? 0 : 1,
                        params.audio_ctx);

                fprintf(stderr, "\n");
            }

            // Run inference
            {
                whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);

                wparams.strategy = params.beam_size > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY;

                wparams.print_realtime   = false;
                wparams.print_progress   = params.print_progress;
                wparams.print_timestamps = !params.no_timestamps;
                wparams.print_special    = params.print_special;
                wparams.translate        = params.translate;
                wparams.language         = params.detect_language ? "auto" : params.language.c_str();
                wparams.detect_language  = params.detect_language;
                wparams.n_threads        = params.n_threads;
                wparams.n_max_text_ctx   = params.max_context >= 0 ? params.max_context : wparams.n_max_text_ctx;
                wparams.offset_ms        = params.offset_t_ms;
                wparams.duration_ms      = params.duration_ms;

                wparams.token_timestamps = params.output_wts || params.max_len > 0;
                wparams.thold_pt         = params.word_thold;
                wparams.entropy_thold    = params.entropy_thold;
                wparams.logprob_thold    = params.logprob_thold;
                wparams.max_len          = params.output_wts && params.max_len == 0 ? 60 : params.max_len;
                wparams.audio_ctx        = params.audio_ctx;

                wparams.greedy.best_of        = params.best_of;
                wparams.beam_search.beam_size = params.beam_size;

                wparams.initial_prompt   = params.prompt.c_str();

                wparams.no_timestamps    = params.no_timestamps;

                whisper_print_user_data user_data = { &params, &pcmf32s };

                // This callback is called for each new segment
                if (!wparams.print_realtime) {
                    wparams.new_segment_callback           = whisper_print_segment_callback;
                    wparams.new_segment_callback_user_data = &user_data;
                }

                // Set progress callback
                wparams.progress_callback = [](struct whisper_context * /*ctx*/, struct whisper_state * /*state*/, int progress, void * user_data) {
                    ProgressWorker* worker = static_cast<ProgressWorker*>(user_data);
                    worker->OnProgress(progress);
                };
                wparams.progress_callback_user_data = this;

                // Cancellation support: checked before each encoder run (coarse)
                // and before each ggml graph computation (fine)
                wparams.encoder_begin_callback = [](struct whisper_context * /*ctx*/, struct whisper_state * /*state*/, void * user_data) {
                    return !static_cast<std::atomic<bool>*>(user_data)->load();
                };
                wparams.encoder_begin_callback_user_data = is_aborted.get();

                wparams.abort_callback = [](void * user_data) {
                    return static_cast<std::atomic<bool>*>(user_data)->load();
                };
                wparams.abort_callback_user_data = is_aborted.get();

                // Set VAD parameters
                wparams.vad            = params.vad;
                wparams.vad_model_path = params.vad_model.c_str();

                wparams.vad_params.threshold               = params.vad_threshold;
                wparams.vad_params.min_speech_duration_ms  = params.vad_min_speech_duration_ms;
                wparams.vad_params.min_silence_duration_ms = params.vad_min_silence_duration_ms;
                wparams.vad_params.max_speech_duration_s   = params.vad_max_speech_duration_s;
                wparams.vad_params.speech_pad_ms           = params.vad_speech_pad_ms;
                wparams.vad_params.samples_overlap         = params.vad_samples_overlap;

                // Append the segments produced by the most recent whisper_full
                // call. base_cs (centiseconds) is added to every timestamp so that
                // results from a sliced per-run buffer (which start at 0) land back
                // on the original audio timeline. For the single-pass path base_cs is 0.
                auto append_segments = [&](struct whisper_context * cctx, int64_t base_cs) {
                    if (result.language.empty() && (params.detect_language || params.language == "auto")) {
                        result.language = whisper_lang_str(whisper_full_lang_id(cctx));
                    }
                    const int n = whisper_full_n_segments(cctx);
                    for (int i = 0; i < n; ++i) {
                        const char *  text = whisper_full_get_segment_text(cctx, i);
                        const int64_t t0   = whisper_full_get_segment_t0(cctx, i) + base_cs;
                        const int64_t t1   = whisper_full_get_segment_t1(cctx, i) + base_cs;
                        std::vector<std::string> seg;
                        seg.emplace_back(to_timestamp(t0, params.comma_in_time));
                        seg.emplace_back(to_timestamp(t1, params.comma_in_time));
                        seg.emplace_back(text);
                        result.segments.emplace_back(std::move(seg));
                    }
                };

                // Approach B/C (faster-whisper-like): re-segment a decode pass using
                // token-level timestamps. Words are reconstructed from tokens (a new
                // word starts on a leading space); a new output segment starts whenever
                // the silence between two words exceeds split_gap_cs, and each segment
                // ends at its last word, so real silences become real gaps and segment
                // ends are never stretched across them. Non-speech bracketed segments
                // (e.g. [BLANK_AUDIO], [Music]) are skipped so they don't fill the gaps.
                // base_cs (centiseconds) is added to every timestamp so results from a
                // sliced per-run buffer land back on the original timeline (0 for a
                // single whole-buffer pass).
                auto append_word_aligned = [&](struct whisper_context * cctx, int64_t base_cs, int64_t split_gap_cs) {
                    if (result.language.empty() && (params.detect_language || params.language == "auto")) {
                        result.language = whisper_lang_str(whisper_full_lang_id(cctx));
                    }
                    const whisper_token eot = whisper_token_eot(cctx);

                    struct word_t { std::string text; int64_t t0; int64_t t1; };
                    std::vector<word_t> words;

                    const int n_seg = whisper_full_n_segments(cctx);
                    for (int i = 0; i < n_seg; ++i) {
                        const char * segtxt = whisper_full_get_segment_text(cctx, i);
                        if (segtxt != nullptr) {
                            const char * p = segtxt;
                            while (*p == ' ') ++p;
                            if (*p == '[' || *p == '(') continue; // skip non-speech segment
                        }
                        const int n_tok = whisper_full_n_tokens(cctx, i);
                        for (int j = 0; j < n_tok; ++j) {
                            const whisper_token_data td = whisper_full_get_token_data(cctx, i, j);
                            if (td.id >= eot) continue; // skip special/timestamp tokens
                            const char * txt = whisper_full_get_token_text(cctx, i, j);
                            if (txt == nullptr || txt[0] == '\0') continue;
                            const std::string t = txt;
                            // Use the VAD-mapped token getters so word times are on the
                            // original timeline even when this pass ran with core VAD on.
                            // (With no VAD mapping they return the raw token times.)
                            const int64_t wt0 = whisper_full_get_token_t0(cctx, i, j) + base_cs;
                            const int64_t wt1 = whisper_full_get_token_t1(cctx, i, j) + base_cs;
                            const bool new_word = words.empty() || t[0] == ' ';
                            if (new_word) {
                                words.push_back({ t, wt0, wt1 });
                            } else {
                                words.back().text += t;
                                if (wt1 > words.back().t1) words.back().t1 = wt1;
                            }
                        }
                    }

                    std::string seg_text;
                    int64_t seg_t0 = -1, seg_t1 = -1, prev_t1 = -1;
                    auto flush = [&]() {
                        if (seg_t0 < 0) return;
                        size_t b = seg_text.find_first_not_of(' ');
                        std::string out = (b == std::string::npos) ? std::string() : seg_text.substr(b);
                        std::vector<std::string> seg;
                        seg.emplace_back(to_timestamp(seg_t0, params.comma_in_time));
                        seg.emplace_back(to_timestamp(seg_t1, params.comma_in_time));
                        seg.emplace_back(std::move(out));
                        result.segments.emplace_back(std::move(seg));
                        seg_text.clear();
                        seg_t0 = seg_t1 = -1;
                    };
                    for (const auto & w : words) {
                        if (seg_t0 >= 0 && split_gap_cs >= 0 && (w.t0 - prev_t1) > split_gap_cs) {
                            flush();
                        }
                        if (seg_t0 < 0) seg_t0 = w.t0;
                        seg_text += w.text;
                        seg_t1  = w.t1;
                        prev_t1 = w.t1;
                    }
                    flush();
                };

                bool handled = false;

                // Approach B: single decode pass + word-gap re-segmentation.
                // Core VAD is used when a model is provided: it removes silence (so the
                // decoder won't hallucinate in it) and the VAD-mapped token getters put
                // word times back on the original timeline. Without a VAD model it runs
                // a plain single pass and token times are already on the timeline.
                if (!handled && params.align_mode == "word" && !pcmf32.empty()) {
                    prog_total_ms = 0.0; // single pass: pass raw 0..100 progress through

                    whisper_full_params rparams = wparams;
                    rparams.vad             = params.vad && !params.vad_model.empty();
                    rparams.token_timestamps = true;
                    rparams.max_len         = 0;     // don't pre-split; we re-segment by word gaps
                    rparams.offset_ms       = params.offset_t_ms;
                    rparams.duration_ms     = params.duration_ms;

                    const int ret = whisper_full_parallel(ctx, rparams, pcmf32.data(), (int) pcmf32.size(), 1);

                    if (is_aborted->load()) break;
                    if (ret != 0) {
                        fprintf(stderr, "failed to process audio (word-aligned)\n");
                        whisper_free(ctx);
                        return 10;
                    }

                    append_word_aligned(ctx, 0, params.word_gap_ms / 10); // ms -> centiseconds
                    handled = true;
                }

                // VAD timeline-aligned path. Approach A ("run") emits whisper's own
                // segments per run; Approach C ("hybrid") additionally re-segments each
                // run by word-level gaps (token timestamps) and clamps segment ends to
                // the last word. Both detect speech regions, group adjacent ones into
                // runs, and transcribe each run from its own sliced buffer so the silence
                // between runs becomes a real gap.
                const bool word_in_runs = (params.align_mode == "hybrid");
                if (!handled && (params.align_mode == "run" || params.align_mode == "hybrid") &&
                    params.vad && !params.vad_model.empty() && params.vad_merge_gap_ms >= 0 && !pcmf32.empty()) {
                    struct whisper_vad_context_params vctx_params = whisper_vad_default_context_params();
                    vctx_params.n_threads = params.n_threads;
                    // NOTE: keep VAD on CPU. whisper.cpp forces GPU VAD off internally
                    // (see whisper_vad_default_context_params / whisper_vad_init_with_params);
                    // running the tiny VAD graph on the Metal backend aborts with
                    // "pre-allocated tensor in a buffer (MTL0) that cannot run the operation".
                    vctx_params.use_gpu   = false;

                    struct whisper_vad_context * vctx =
                        whisper_vad_init_from_file_with_params(params.vad_model.c_str(), vctx_params);

                    if (vctx == nullptr) {
                        fprintf(stderr, "%s: warning: failed to init VAD context, falling back to single-pass\n", __func__);
                    } else {
                        struct whisper_vad_params vparams = whisper_vad_default_params();
                        vparams.threshold               = params.vad_threshold;
                        vparams.min_speech_duration_ms  = params.vad_min_speech_duration_ms;
                        vparams.min_silence_duration_ms = params.vad_min_silence_duration_ms;
                        vparams.max_speech_duration_s   = params.vad_max_speech_duration_s;
                        vparams.speech_pad_ms           = params.vad_speech_pad_ms;
                        vparams.samples_overlap         = params.vad_samples_overlap;

                        whisper_vad_segments * segs =
                            whisper_vad_segments_from_samples(vctx, vparams, pcmf32.data(), (int) pcmf32.size());

                        if (segs != nullptr && whisper_vad_segments_n_segments(segs) > 0) {
                            const int n_vad = whisper_vad_segments_n_segments(segs);

                            // Group adjacent VAD segments into runs. VAD times are
                            // in centiseconds (1 cs = 10 ms).
                            const double merge_gap_cs = params.vad_merge_gap_ms / 10.0;
                            struct run_t { double start_cs; double end_cs; };
                            std::vector<run_t> runs;
                            for (int i = 0; i < n_vad; ++i) {
                                const double s = whisper_vad_segments_get_segment_t0(segs, i);
                                const double e = whisper_vad_segments_get_segment_t1(segs, i);
                                if (!runs.empty() && (s - runs.back().end_cs) <= merge_gap_cs) {
                                    if (e > runs.back().end_cs) runs.back().end_cs = e;
                                } else {
                                    runs.push_back({ s, e });
                                }
                            }

                            const double audio_ms = (double) pcmf32.size() * 1000.0 / WHISPER_SAMPLE_RATE;

                            // Weight progress by each run's duration so the JS side
                            // gets a single monotonic 0..100.
                            prog_total_ms = 0.0;
                            for (const auto & r : runs) prog_total_ms += (r.end_cs - r.start_cs) * 10.0;
                            if (prog_total_ms <= 0.0) prog_total_ms = 1.0;
                            prog_done_ms = 0.0;

                            if (!params.no_prints) {
                                fprintf(stderr, "%s: VAD aligned: %d speech segment(s) -> %d run(s)\n",
                                        __func__, n_vad, (int) runs.size());
                            }

                            for (size_t ri = 0; ri < runs.size(); ++ri) {
                                if (is_aborted->load()) break;

                                double off_ms = runs[ri].start_cs * 10.0;
                                double end_ms = runs[ri].end_cs   * 10.0;
                                if (off_ms < 0.0)      off_ms = 0.0;
                                if (end_ms > audio_ms) end_ms = audio_ms;
                                if (end_ms <= off_ms)  continue;
                                const double dur_ms = end_ms - off_ms;

                                // Copy just this run's samples into their own buffer.
                                // whisper_full feeds the encoder a full 30s mel window
                                // starting at offset_ms and only uses duration_ms to stop
                                // the outer seek loop, so passing the whole buffer with
                                // offset/duration would let neighbouring speech bleed into
                                // short runs. Slicing guarantees the encoder only sees this
                                // region; timestamps come back relative to the slice and are
                                // shifted onto the original timeline via base_cs.
                                size_t s0 = (size_t) (off_ms * WHISPER_SAMPLE_RATE / 1000.0 + 0.5);
                                size_t s1 = (size_t) (end_ms * WHISPER_SAMPLE_RATE / 1000.0 + 0.5);
                                if (s1 > pcmf32.size()) s1 = pcmf32.size();
                                if (s0 >= s1) continue;
                                std::vector<float> chunk(pcmf32.begin() + s0, pcmf32.begin() + s1);

                                const int64_t base_cs = (int64_t) (off_ms / 10.0 + 0.5);

                                prog_cur_ms = dur_ms;

                                whisper_full_params rparams = wparams;
                                rparams.vad         = false; // we already segmented with VAD
                                rparams.offset_ms   = 0;
                                rparams.duration_ms = 0;
                                if (word_in_runs) {
                                    rparams.token_timestamps = true; // hybrid: need word-level times
                                    rparams.max_len          = 0;    // we re-segment by word gaps
                                }

                                if (!params.no_prints) {
                                    fprintf(stderr, "%s: run %d: %.2fs..%.2fs (%.2fs, %d samples)\n",
                                            __func__, (int) ri, off_ms / 1000.0, end_ms / 1000.0,
                                            dur_ms / 1000.0, (int) chunk.size());
                                }

                                const int ret = whisper_full_parallel(ctx, rparams, chunk.data(), (int) chunk.size(), 1);

                                if (is_aborted->load()) break;
                                if (ret != 0) {
                                    fprintf(stderr, "failed to process audio (VAD run %d)\n", (int) ri);
                                    whisper_vad_free_segments(segs);
                                    whisper_vad_free(vctx);
                                    whisper_free(ctx);
                                    return 10;
                                }

                                if (word_in_runs) {
                                    append_word_aligned(ctx, base_cs, params.word_gap_ms / 10);
                                } else {
                                    append_segments(ctx, base_cs);
                                }
                                prog_done_ms += dur_ms;
                            }

                            handled = true;
                        }

                        if (segs != nullptr) whisper_vad_free_segments(segs);
                        whisper_vad_free(vctx);
                    }
                }

                if (is_aborted->load()) {
                    // cancelled - keep the segments transcribed so far
                    break;
                }

                // Fallback / legacy path: single pass over the whole buffer.
                // Taken for align_mode == "legacy", or when "run"/"hybrid" is requested
                // but VAD is off / unavailable / vad_merge_gap_ms < 0. "word"/"hybrid"
                // still word-align here (degrading to a VAD-less single pass); "run"/
                // "legacy" keep the continuous timeline (with core VAD if params.vad).
                if (!handled) {
                    prog_total_ms = 0.0; // pass the raw 0..100 progress through

                    const bool word_fallback =
                        (params.align_mode == "word" || params.align_mode == "hybrid");

                    whisper_full_params rparams = wparams;
                    rparams.offset_ms   = params.offset_t_ms;
                    rparams.duration_ms = params.duration_ms;
                    if (word_fallback) {
                        rparams.vad              = false; // token timestamps must be on the original timeline
                        rparams.token_timestamps = true;
                        rparams.max_len          = 0;
                    }

                    const int n_proc = word_fallback ? 1 : params.n_processors;
                    const int ret = whisper_full_parallel(ctx, rparams, pcmf32.data(), (int) pcmf32.size(), n_proc);

                    if (is_aborted->load()) {
                        // cancelled - keep the segments transcribed so far
                        break;
                    }
                    if (ret != 0) {
                        fprintf(stderr, "failed to process audio\n");
                        whisper_free(ctx);
                        return 10;
                    }

                    if (word_fallback) {
                        append_word_aligned(ctx, 0, params.word_gap_ms / 10);
                    } else {
                        append_segments(ctx, 0);
                    }
                }
            }
        }

        // NOTE: result.segments and result.language are populated incrementally by
        // append_segments() after each whisper_full call (see the inference loop),
        // so the timestamps already sit on the original timeline with VAD gaps.

        whisper_print_timings(ctx);
        whisper_free(ctx);

        return 0;
    }
};

Napi::Value whisper(const Napi::CallbackInfo& info) {
  Napi::Env env = info.Env();
  if (info.Length() <= 0 || !info[0].IsObject()) {
    Napi::TypeError::New(env, "object expected").ThrowAsJavaScriptException();
  }
  whisper_params params;

  Napi::Object whisper_params = info[0].As<Napi::Object>();
  std::string language = whisper_params.Get("language").As<Napi::String>();
  std::string model = whisper_params.Get("model").As<Napi::String>();
  std::string input = whisper_params.Get("fname_inp").As<Napi::String>();

  bool use_gpu = true;
  if (whisper_params.Has("use_gpu") && whisper_params.Get("use_gpu").IsBoolean()) {
    use_gpu = whisper_params.Get("use_gpu").As<Napi::Boolean>();
  }

  bool flash_attn = false;
  if (whisper_params.Has("flash_attn") && whisper_params.Get("flash_attn").IsBoolean()) {
    flash_attn = whisper_params.Get("flash_attn").As<Napi::Boolean>();
  }

  bool no_prints = false;
  if (whisper_params.Has("no_prints") && whisper_params.Get("no_prints").IsBoolean()) {
    no_prints = whisper_params.Get("no_prints").As<Napi::Boolean>();
  }

  bool no_timestamps = false;
  if (whisper_params.Has("no_timestamps") && whisper_params.Get("no_timestamps").IsBoolean()) {
    no_timestamps = whisper_params.Get("no_timestamps").As<Napi::Boolean>();
  }

  bool detect_language = false;
  if (whisper_params.Has("detect_language") && whisper_params.Get("detect_language").IsBoolean()) {
    detect_language = whisper_params.Get("detect_language").As<Napi::Boolean>();
  }

  int32_t audio_ctx = 0;
  if (whisper_params.Has("audio_ctx") && whisper_params.Get("audio_ctx").IsNumber()) {
    audio_ctx = whisper_params.Get("audio_ctx").As<Napi::Number>();
  }

  bool comma_in_time = true;
  if (whisper_params.Has("comma_in_time") && whisper_params.Get("comma_in_time").IsBoolean()) {
    comma_in_time = whisper_params.Get("comma_in_time").As<Napi::Boolean>();
  }

  int32_t max_len = 0;
  if (whisper_params.Has("max_len") && whisper_params.Get("max_len").IsNumber()) {
    max_len = whisper_params.Get("max_len").As<Napi::Number>();
  }

  // Add support for max_context
  int32_t max_context = -1;
  if (whisper_params.Has("max_context") && whisper_params.Get("max_context").IsNumber()) {
    max_context = whisper_params.Get("max_context").As<Napi::Number>();
  }

  // support prompt
  std::string prompt = "";
  if (whisper_params.Has("prompt") && whisper_params.Get("prompt").IsString()) {
    prompt = whisper_params.Get("prompt").As<Napi::String>();
  }

  // Add support for print_progress
  bool print_progress = false;
  if (whisper_params.Has("print_progress") && whisper_params.Get("print_progress").IsBoolean()) {
    print_progress = whisper_params.Get("print_progress").As<Napi::Boolean>();
  }
  // Add support for progress_callback
  Napi::Function progress_callback;
  if (whisper_params.Has("progress_callback") && whisper_params.Get("progress_callback").IsFunction()) {
    progress_callback = whisper_params.Get("progress_callback").As<Napi::Function>();
  }

  // Add support for VAD parameters
  bool vad = false;
  if (whisper_params.Has("vad") && whisper_params.Get("vad").IsBoolean()) {
    vad = whisper_params.Get("vad").As<Napi::Boolean>();
  }

  std::string vad_model = "";
  if (whisper_params.Has("vad_model") && whisper_params.Get("vad_model").IsString()) {
    vad_model = whisper_params.Get("vad_model").As<Napi::String>();
  }

  float vad_threshold = 0.5f;
  if (whisper_params.Has("vad_threshold") && whisper_params.Get("vad_threshold").IsNumber()) {
    vad_threshold = whisper_params.Get("vad_threshold").As<Napi::Number>();
  }

  int vad_min_speech_duration_ms = 250;
  if (whisper_params.Has("vad_min_speech_duration_ms") && whisper_params.Get("vad_min_speech_duration_ms").IsNumber()) {
    vad_min_speech_duration_ms = whisper_params.Get("vad_min_speech_duration_ms").As<Napi::Number>();
  }

  int vad_min_silence_duration_ms = 100;
  if (whisper_params.Has("vad_min_silence_duration_ms") && whisper_params.Get("vad_min_silence_duration_ms").IsNumber()) {
    vad_min_silence_duration_ms = whisper_params.Get("vad_min_silence_duration_ms").As<Napi::Number>();
  }

  float vad_max_speech_duration_s = FLT_MAX;
  if (whisper_params.Has("vad_max_speech_duration_s") && whisper_params.Get("vad_max_speech_duration_s").IsNumber()) {
    vad_max_speech_duration_s = whisper_params.Get("vad_max_speech_duration_s").As<Napi::Number>();
  }

  int vad_speech_pad_ms = 30;
  if (whisper_params.Has("vad_speech_pad_ms") && whisper_params.Get("vad_speech_pad_ms").IsNumber()) {
    vad_speech_pad_ms = whisper_params.Get("vad_speech_pad_ms").As<Napi::Number>();
  }

  float vad_samples_overlap = 0.1f;
  if (whisper_params.Has("vad_samples_overlap") && whisper_params.Get("vad_samples_overlap").IsNumber()) {
    vad_samples_overlap = whisper_params.Get("vad_samples_overlap").As<Napi::Number>();
  }

  // Controls the VAD timeline-aligned (faster-whisper-like) mode. Adjacent VAD
  // speech segments closer than this (ms) are merged into one transcription run;
  // larger silences become real gaps. A negative value disables the aligned mode
  // and keeps the legacy continuous-timeline behavior.
  int vad_merge_gap_ms = 2000;
  if (whisper_params.Has("vad_merge_gap_ms") && whisper_params.Get("vad_merge_gap_ms").IsNumber()) {
    vad_merge_gap_ms = whisper_params.Get("vad_merge_gap_ms").As<Napi::Number>();
  }

  // Timeline alignment strategy: "hybrid" (Approach C, default), "run" (Approach A),
  // "word" (Approach B, faster-whisper-like), or "legacy" (continuous).
  // See whisper_params::align_mode.
  std::string align_mode = "hybrid";
  if (whisper_params.Has("align_mode") && whisper_params.Get("align_mode").IsString()) {
    align_mode = whisper_params.Get("align_mode").As<Napi::String>();
  }

  int word_gap_ms = 500;
  if (whisper_params.Has("word_gap_ms") && whisper_params.Get("word_gap_ms").IsNumber()) {
    word_gap_ms = whisper_params.Get("word_gap_ms").As<Napi::Number>();
  }

  Napi::Value pcmf32Value = whisper_params.Get("pcmf32");
  std::vector<float> pcmf32_vec;
  if (pcmf32Value.IsTypedArray()) {
    Napi::Float32Array pcmf32 = pcmf32Value.As<Napi::Float32Array>();
    size_t length = pcmf32.ElementLength();
    pcmf32_vec.reserve(length);
    for (size_t i = 0; i < length; i++) {
      pcmf32_vec.push_back(pcmf32[i]);
    }
  }

  params.language = language;
  params.model = model;
  params.fname_inp.emplace_back(input);
  params.use_gpu = use_gpu;
  params.flash_attn = flash_attn;
  params.no_prints = no_prints;
  params.no_timestamps = no_timestamps;
  params.audio_ctx = audio_ctx;
  params.pcmf32 = pcmf32_vec;
  params.comma_in_time = comma_in_time;
  params.max_len = max_len;
  params.max_context = max_context;
  params.print_progress = print_progress;
  params.prompt = prompt;
  params.detect_language = detect_language;

  // Set VAD parameters
  params.vad = vad;
  params.vad_model = vad_model;
  params.vad_threshold = vad_threshold;
  params.vad_min_speech_duration_ms = vad_min_speech_duration_ms;
  params.vad_min_silence_duration_ms = vad_min_silence_duration_ms;
  params.vad_max_speech_duration_s = vad_max_speech_duration_s;
  params.vad_speech_pad_ms = vad_speech_pad_ms;
  params.vad_samples_overlap = vad_samples_overlap;
  params.vad_merge_gap_ms = vad_merge_gap_ms;
  params.align_mode = align_mode;
  params.word_gap_ms = word_gap_ms;

  // Cancellation support: an AbortSignal can be passed via params.signal.
  // Its "abort" event sets a shared flag which is polled by the whisper.cpp
  // abort callbacks on the worker thread.
  auto is_aborted = std::make_shared<std::atomic<bool>>(false);
  if (whisper_params.Has("signal") && whisper_params.Get("signal").IsObject()) {
    Napi::Object signal = whisper_params.Get("signal").As<Napi::Object>();

    if (signal.Get("aborted").ToBoolean().Value()) {
      is_aborted->store(true);
    } else if (signal.Has("addEventListener") && signal.Get("addEventListener").IsFunction()) {
      Napi::Function add_listener = signal.Get("addEventListener").As<Napi::Function>();
      Napi::Function on_abort = Napi::Function::New(env, [is_aborted](const Napi::CallbackInfo &) {
        is_aborted->store(true);
      });
      Napi::Object options = Napi::Object::New(env);
      options.Set("once", Napi::Boolean::New(env, true));
      add_listener.Call(signal, { Napi::String::New(env, "abort"), on_abort, options });
    }
  }

  Napi::Function callback = info[1].As<Napi::Function>();
  // Create a new Worker class with progress callback support
  ProgressWorker* worker = new ProgressWorker(callback, params, progress_callback, env, is_aborted);
  worker->Queue();
  return env.Undefined();
}


Napi::Object Init(Napi::Env env, Napi::Object exports) {
  exports.Set(
      Napi::String::New(env, "whisper"),
      Napi::Function::New(env, whisper)
  );
  return exports;
}

NODE_API_MODULE(whisper, Init);
