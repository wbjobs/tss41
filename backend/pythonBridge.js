const { spawn } = require('child_process');
const path = require('path');

class PythonBridge {
  constructor(scriptPath, pythonExecutable = 'python3') {
    this.scriptPath = scriptPath;
    this.pythonExecutable = pythonExecutable;
  }

  async execute(inputData, timeoutMs = 30000) {
    return new Promise((resolve, reject) => {
      const pythonProcess = spawn(this.pythonExecutable, [this.scriptPath], {
        stdio: ['pipe', 'pipe', 'pipe']
      });

      let stdout = '';
      let stderr = '';
      let timedOut = false;

      const timeout = setTimeout(() => {
        timedOut = true;
        pythonProcess.kill('SIGTERM');
        reject(new Error('Python script execution timed out'));
      }, timeoutMs);

      pythonProcess.stdout.on('data', (data) => {
        stdout += data.toString();
      });

      pythonProcess.stderr.on('data', (data) => {
        stderr += data.toString();
      });

      pythonProcess.on('error', (err) => {
        if (!timedOut) {
          clearTimeout(timeout);
          reject(new Error(`Failed to start Python process: ${err.message}`));
        }
      });

      pythonProcess.on('close', (code) => {
        if (!timedOut) {
          clearTimeout(timeout);
          
          if (code !== 0) {
            reject(new Error(`Python script exited with code ${code}: ${stderr}`));
            return;
          }

          try {
            const result = JSON.parse(stdout.trim());
            resolve(result);
          } catch (parseError) {
            reject(new Error(`Failed to parse Python output: ${parseError.message}\nOutput: ${stdout}`));
          }
        }
      });

      try {
        pythonProcess.stdin.write(JSON.stringify(inputData));
        pythonProcess.stdin.end();
      } catch (writeError) {
        clearTimeout(timeout);
        reject(new Error(`Failed to write to Python stdin: ${writeError.message}`));
      }
    });
  }

  async compareAudio(audio1Base64, audio2Base64, sampleRate = 16000, threshold = 0.75) {
    const inputData = {
      audio1: audio1Base64,
      audio2: audio2Base64,
      sample_rate: sampleRate,
      threshold: threshold
    };

    return this.execute(inputData);
  }
}

class AudioMatcher {
  constructor(options = {}) {
    const scriptPath = options.scriptPath || path.join(__dirname, 'signal_processing', 'mfcc_dtw.py');
    const pythonExecutable = options.pythonExecutable || 'python3';
    this.bridge = new PythonBridge(scriptPath, pythonExecutable);
    this.defaultThreshold = options.threshold || 0.75;
  }

  async match(audio1, audio2, sampleRate) {
    try {
      const result = await this.bridge.compareAudio(
        audio1,
        audio2,
        sampleRate,
        this.defaultThreshold
      );

      return {
        success: !result.error,
        ...result
      };
    } catch (error) {
      return {
        success: false,
        is_match: false,
        error: error.message
      };
    }
  }
}

module.exports = { PythonBridge, AudioMatcher };
