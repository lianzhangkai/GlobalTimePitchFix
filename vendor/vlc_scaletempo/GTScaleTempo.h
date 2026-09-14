#pragma once

class GTScaleTempo {
public:
    GTScaleTempo(int sampleRate, int channels);
    ~GTScaleTempo();

    bool valid() const;
    void reset();
    void setSpeed(float speed);
    float speed() const;

    // Interleaved float PCM, [-1, 1]. Frames count is per-channel frames.
    bool push(const float *samples, int frames);
    int availableFrames() const;
    int read(float *dst, int maxFrames);

private:
    GTScaleTempo(const GTScaleTempo &);
    GTScaleTempo &operator=(const GTScaleTempo &);

    bool ensureInputCapacity(int framesNeeded);
    bool ensureOutputCapacity(int additionalFrames);
    void compactOutput();
    void processAvailable();
    bool processOneStride();
    int findBestOverlapOffset() const;

    int sampleRate_;
    int channels_;
    float speed_;

    int strideFrames_;
    int overlapFrames_;
    int standingFrames_;
    int searchFrames_;
    int queueMaxFrames_;

    float *input_;
    int inputFrames_;
    int inputCapacityFrames_;
    int skipFrames_;

    float *overlap_;

    float *output_;
    int outputFrames_;
    int outputReadFrame_;
    int outputCapacityFrames_;

    double consumeError_;
    bool valid_;
};
