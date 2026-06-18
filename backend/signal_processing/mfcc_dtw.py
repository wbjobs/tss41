import numpy as np
import sys
import json
import base64

def normalize_audio(signal, target_rms=0.1):
    signal = signal - np.mean(signal)
    
    rms = np.sqrt(np.mean(signal ** 2))
    if rms < 1e-8:
        return signal
    
    gain = target_rms / rms
    normalized = signal * gain
    
    peak = np.max(np.abs(normalized))
    if peak > 0.95:
        normalized = normalized * (0.95 / peak)
    
    return normalized

def remove_dc_offset(signal):
    return signal - np.mean(signal)

def detect_clipping(signal, threshold=0.95):
    clipped_samples = np.sum(np.abs(signal) >= threshold)
    clipping_ratio = clipped_samples / len(signal)
    return clipping_ratio

def soft_clip_repair(signal, threshold=0.95, strength=0.5):
    signal = signal.copy()
    mask = np.abs(signal) > threshold
    
    if not np.any(mask):
        return signal
    
    sign = np.sign(signal)
    abs_signal = np.abs(signal)
    overshoot = abs_signal - threshold
    repaired = threshold + overshoot * (1 - strength)
    repaired = np.minimum(repaired, threshold * 1.2)
    
    signal[mask] = sign[mask] * repaired[mask]
    return signal

def pre_emphasis(signal, alpha=0.97):
    return np.append(signal[0], signal[1:] - alpha * signal[:-1])

def framing(signal, sample_rate, frame_size=0.025, frame_stride=0.01):
    frame_length = int(round(frame_size * sample_rate))
    frame_step = int(round(frame_stride * sample_rate))
    signal_length = len(signal)
    num_frames = int(np.ceil(float(np.abs(signal_length - frame_length)) / frame_step + 1))
    
    pad_signal_length = num_frames * frame_step + frame_length
    z = np.zeros((pad_signal_length - signal_length))
    pad_signal = np.append(signal, z)
    
    indices = np.tile(np.arange(0, frame_length), (num_frames, 1)) + \
              np.tile(np.arange(0, num_frames * frame_step, frame_step), (frame_length, 1)).T
    frames = pad_signal[indices.astype(np.int32, copy=False)]
    return frames

def windowing(frames):
    hamming = np.hamming(frames.shape[1])
    return frames * hamming

def power_spectrum(frames, NFFT=512):
    mag_frames = np.absolute(np.fft.rfft(frames, NFFT))
    pow_frames = ((1.0 / NFFT) * (mag_frames ** 2))
    return pow_frames

def mel_filter_banks(pow_frames, sample_rate, nfilt=40, NFFT=512):
    low_freq_mel = 0
    high_freq_mel = (2595 * np.log10(1 + (sample_rate / 2) / 700))
    mel_points = np.linspace(low_freq_mel, high_freq_mel, nfilt + 2)
    hz_points = (700 * (10 ** (mel_points / 2595) - 1))
    bin = np.floor((NFFT + 1) * hz_points / sample_rate)
    
    fbank = np.zeros((nfilt, int(np.floor(NFFT / 2 + 1))))
    for m in range(1, nfilt + 1):
        f_m_minus = int(bin[m - 1])
        f_m = int(bin[m])
        f_m_plus = int(bin[m + 1])
        
        for k in range(f_m_minus, f_m):
            fbank[m - 1, k] = (k - bin[m - 1]) / (bin[m] - bin[m - 1])
        for k in range(f_m, f_m_plus):
            fbank[m - 1, k] = (bin[m + 1] - k) / (bin[m + 1] - bin[m])
    
    filter_banks = np.dot(pow_frames, fbank.T)
    filter_banks = np.where(filter_banks == 0, np.finfo(float).eps, filter_banks)
    filter_banks = 20 * np.log10(filter_banks)
    return filter_banks

def discrete_cosine_transform(filter_banks, num_ceps=13):
    n_frames, n_coeffs = filter_banks.shape
    cepstral = np.zeros((n_frames, num_ceps))
    
    for i in range(n_frames):
        for j in range(num_ceps):
            sum_val = 0.0
            for k in range(n_coeffs):
                sum_val += filter_banks[i, k] * np.cos(np.pi * j * (k + 0.5) / n_coeffs)
            cepstral[i, j] = sum_val * np.sqrt(2.0 / n_coeffs)
    
    return cepstral

def cmvn_normalization(mfcc):
    if len(mfcc) <= 1:
        return mfcc
    
    mean = np.mean(mfcc, axis=0)
    std = np.std(mfcc, axis=0) + 1e-8
    normalized = (mfcc - mean) / std
    
    return normalized

def l2_normalize_frames(mfcc):
    norms = np.linalg.norm(mfcc, axis=1, keepdims=True) + 1e-8
    return mfcc / norms

def linear_interpolate(x, y, x_new):
    n = len(x)
    m = len(x_new)
    y_new = np.zeros(m)
    
    for i in range(m):
        xi = x_new[i]
        
        if xi <= x[0]:
            y_new[i] = y[0]
            continue
        if xi >= x[-1]:
            y_new[i] = y[-1]
            continue
        
        idx = np.searchsorted(x, xi) - 1
        idx = max(0, min(n - 2, idx))
        
        x0, x1 = x[idx], x[idx + 1]
        y0, y1 = y[idx], y[idx + 1]
        
        if x1 == x0:
            y_new[i] = y0
        else:
            t = (xi - x0) / (x1 - x0)
            y_new[i] = y0 + t * (y1 - y0)
    
    return y_new

def time_normalize(mfcc, target_frames=100):
    n_frames, n_coeffs = mfcc.shape
    
    if n_frames == target_frames:
        return mfcc
    
    original_indices = np.arange(n_frames, dtype=np.float64)
    target_indices = np.linspace(0, n_frames - 1, target_frames)
    
    normalized = np.zeros((target_frames, n_coeffs))
    
    for i in range(n_coeffs):
        normalized[:, i] = linear_interpolate(original_indices, mfcc[:, i], target_indices)
    
    return normalized

def feature_standardization(mfcc):
    flattened = mfcc.flatten()
    mean = np.mean(flattened)
    std = np.std(flattened) + 1e-8
    
    standardized = (mfcc - mean) / std
    return standardized

def extract_mfcc(audio_data, sample_rate=16000, num_ceps=13, nfilt=40, NFFT=512):
    signal = audio_data.copy()
    
    signal = remove_dc_offset(signal)
    
    clipping_ratio = detect_clipping(signal)
    if clipping_ratio > 0.001:
        signal = soft_clip_repair(signal, threshold=0.95, strength=0.6)
    
    signal = normalize_audio(signal, target_rms=0.1)
    
    signal = pre_emphasis(signal)
    frames = framing(signal, sample_rate)
    frames = windowing(frames)
    pow_frames = power_spectrum(frames, NFFT)
    filter_banks = mel_filter_banks(pow_frames, sample_rate, nfilt, NFFT)
    mfcc = discrete_cosine_transform(filter_banks, num_ceps)
    
    mfcc = cmvn_normalization(mfcc)
    
    mfcc = feature_standardization(mfcc)
    
    mfcc = l2_normalize_frames(mfcc)
    
    return mfcc

def dtw_distance(seq1, seq2, max_warping_window=None):
    n, m = seq1.shape[0], seq2.shape[0]
    
    if max_warping_window is None:
        max_warping_window = max(n, m)
    
    w = max(max_warping_window, abs(n - m))
    
    D = np.full((n + 1, m + 1), np.inf)
    D[0, 0] = 0
    
    for i in range(1, n + 1):
        for j in range(max(1, i - w), min(m + 1, i + w + 1)):
            cost = np.linalg.norm(seq1[i - 1] - seq2[j - 1])
            D[i, j] = cost + min(D[i - 1, j], D[i, j - 1], D[i - 1, j - 1])
    
    path = []
    i, j = n, m
    while i > 0 or j > 0:
        path.append((i - 1, j - 1))
        if i == 0:
            j -= 1
        elif j == 0:
            i -= 1
        else:
            choices = [D[i - 1, j], D[i, j - 1], D[i - 1, j - 1]]
            min_idx = np.argmin(choices)
            if min_idx == 0:
                i -= 1
            elif min_idx == 1:
                j -= 1
            else:
                i -= 1
                j -= 1
    
    path.reverse()
    return D[n, m], path

def normalize_mfcc(mfcc):
    mean = np.mean(mfcc, axis=0)
    std = np.std(mfcc, axis=0) + 1e-8
    return (mfcc - mean) / std

def calculate_similarity(mfcc1, mfcc2, threshold=0.8):
    mfcc1_arr = np.array(mfcc1)
    mfcc2_arr = np.array(mfcc2)
    
    mfcc1_norm = cmvn_normalization(mfcc1_arr)
    mfcc2_norm = cmvn_normalization(mfcc2_arr)
    
    mfcc1_norm = feature_standardization(mfcc1_norm)
    mfcc2_norm = feature_standardization(mfcc2_norm)
    
    mfcc1_norm = l2_normalize_frames(mfcc1_norm)
    mfcc2_norm = l2_normalize_frames(mfcc2_norm)
    
    min_frames = min(mfcc1_norm.shape[0], mfcc2_norm.shape[0])
    target_frames = max(50, min(min_frames, 200))
    mfcc1_norm = time_normalize(mfcc1_norm, target_frames)
    mfcc2_norm = time_normalize(mfcc2_norm, target_frames)
    
    distance, path = dtw_distance(mfcc1_norm, mfcc2_norm)
    
    path_length = len(path)
    normalized_distance = distance / path_length
    
    similarity = 1.0 / (1.0 + normalized_distance)
    
    is_match = similarity > threshold
    
    return {
        'distance': float(distance),
        'normalized_distance': float(normalized_distance),
        'similarity_score': float(similarity),
        'is_match': bool(is_match),
        'threshold': float(threshold),
        'path_length': path_length,
        'mfcc1_frames': mfcc1_arr.shape[0],
        'mfcc2_frames': mfcc2_arr.shape[0],
        'normalized_frames': target_frames
    }

def main():
    try:
        input_data = json.loads(sys.stdin.read())
        
        audio1_bytes = base64.b64decode(input_data['audio1'])
        audio2_bytes = base64.b64decode(input_data['audio2'])
        
        audio1 = np.frombuffer(audio1_bytes, dtype=np.float32)
        audio2 = np.frombuffer(audio2_bytes, dtype=np.float32)
        
        sample_rate = input_data.get('sample_rate', 16000)
        threshold = input_data.get('threshold', 0.75)
        
        clipping1 = float(detect_clipping(audio1))
        clipping2 = float(detect_clipping(audio2))
        
        mfcc1 = extract_mfcc(audio1, sample_rate)
        mfcc2 = extract_mfcc(audio2, sample_rate)
        
        result = calculate_similarity(mfcc1.tolist(), mfcc2.tolist(), threshold)
        result['input_clipping_ratio_1'] = clipping1
        result['input_clipping_ratio_2'] = clipping2
        
        print(json.dumps(result))
        sys.stdout.flush()
        
    except Exception as e:
        error_result = {
            'error': str(e),
            'is_match': False
        }
        print(json.dumps(error_result))
        sys.stdout.flush()

if __name__ == '__main__':
    main()
