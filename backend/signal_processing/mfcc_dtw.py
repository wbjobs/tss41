import numpy as np
import sys
import json
import base64

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

def extract_mfcc(audio_data, sample_rate=16000, num_ceps=13, nfilt=40, NFFT=512):
    signal = pre_emphasis(audio_data)
    frames = framing(signal, sample_rate)
    frames = windowing(frames)
    pow_frames = power_spectrum(frames, NFFT)
    filter_banks = mel_filter_banks(pow_frames, sample_rate, nfilt, NFFT)
    mfcc = discrete_cosine_transform(filter_banks, num_ceps)
    
    if len(mfcc) > 1:
        mfcc = mfcc - (np.mean(mfcc, axis=0) + 1e-8)
    
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

def calculate_similarity(mfcc1, mfcc2, threshold=1000.0):
    mfcc1_norm = normalize_mfcc(np.array(mfcc1))
    mfcc2_norm = normalize_mfcc(np.array(mfcc2))
    
    distance, path = dtw_distance(mfcc1_norm, mfcc2_norm)
    
    path_length = len(path)
    normalized_distance = distance / path_length
    
    is_match = normalized_distance < threshold
    
    return {
        'distance': float(distance),
        'normalized_distance': float(normalized_distance),
        'is_match': bool(is_match),
        'threshold': float(threshold),
        'path_length': path_length
    }

def main():
    try:
        input_data = json.loads(sys.stdin.read())
        
        audio1_bytes = base64.b64decode(input_data['audio1'])
        audio2_bytes = base64.b64decode(input_data['audio2'])
        
        audio1 = np.frombuffer(audio1_bytes, dtype=np.float32)
        audio2 = np.frombuffer(audio2_bytes, dtype=np.float32)
        
        sample_rate = input_data.get('sample_rate', 16000)
        threshold = input_data.get('threshold', 1000.0)
        
        mfcc1 = extract_mfcc(audio1, sample_rate).tolist()
        mfcc2 = extract_mfcc(audio2, sample_rate).tolist()
        
        result = calculate_similarity(mfcc1, mfcc2, threshold)
        result['mfcc1_frames'] = len(mfcc1)
        result['mfcc2_frames'] = len(mfcc2)
        
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
