const https = require('https');

class TranslationEngine {
  constructor() {
    this.cache = new Map();
    this.maxCacheSize = 200;
  }

  async translate(text, from = 'zh-CN', to = 'en') {
    if (!text || !text.trim()) return '';
    const trimmed = text.trim();
    const cacheKey = `${from}:${to}:${trimmed}`;

    if (this.cache.has(cacheKey)) {
      return this.cache.get(cacheKey);
    }

    let result = '';
    let lastError = null;

    // Channel 1: Google Chrome Extension API (highest rate limit & fast)
    try {
      result = await this._fetchGoogleChromeEx(trimmed, from, to);
    } catch (err1) {
      lastError = err1;
      // Channel 2: Google APIs GTX Endpoint with browser headers
      try {
        result = await this._fetchGoogleGtx(trimmed, from, to);
      } catch (err2) {
        lastError = err2;
        // Channel 3: Google Mobile Web Endpoint
        try {
          result = await this._fetchGoogleWeb(trimmed, from, to);
        } catch (err3) {
          throw new Error(`Google API rate limited (429): all channels busy, please retry in a moment.`);
        }
      }
    }

    if (result) {
      if (this.cache.size >= this.maxCacheSize) {
        const firstKey = this.cache.keys().next().value;
        this.cache.delete(firstKey);
      }
      this.cache.set(cacheKey, result);
    }

    return result;
  }

  _fetchGoogleChromeEx(text, from, to) {
    return new Promise((resolve, reject) => {
      const targetLang = to.toLowerCase().startsWith('en') ? 'en' : to;
      const sourceLang = from.toLowerCase().startsWith('zh') ? 'zh-CN' : from;
      const url = `https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl=${encodeURIComponent(sourceLang)}&tl=${encodeURIComponent(targetLang)}&q=${encodeURIComponent(text)}`;

      const options = {
        headers: {
          'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
          'Accept': '*/*',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
        },
        timeout: 4000
      };

      https.get(url, options, (res) => {
        if (res.statusCode !== 200) {
          return reject(new Error(`Google Chrome API status ${res.statusCode}`));
        }

        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => {
          try {
            const parsed = JSON.parse(data);
            if (Array.isArray(parsed)) {
              const resText = parsed.map(item => (typeof item === 'string' ? item : item[0])).filter(Boolean).join('');
              resolve(resText.trim());
            } else {
              reject(new Error('Unexpected Chrome API response'));
            }
          } catch (e) {
            reject(e);
          }
        });
      }).on('error', reject);
    });
  }

  _fetchGoogleGtx(text, from, to) {
    return new Promise((resolve, reject) => {
      const targetLang = to.toLowerCase().startsWith('en') ? 'en' : to;
      const sourceLang = from.toLowerCase().startsWith('zh') ? 'zh-CN' : from;
      const url = `https://translate.googleapis.com/translate_a/single?client=gtx&sl=${encodeURIComponent(sourceLang)}&tl=${encodeURIComponent(targetLang)}&dt=t&q=${encodeURIComponent(text)}`;

      const options = {
        headers: {
          'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
          'Accept': '*/*',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
        },
        timeout: 4000
      };

      https.get(url, options, (res) => {
        if (res.statusCode !== 200) {
          return reject(new Error(`Google GTX API status ${res.statusCode}`));
        }

        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => {
          try {
            const parsed = JSON.parse(data);
            if (Array.isArray(parsed) && Array.isArray(parsed[0])) {
              const result = parsed[0].map(item => item[0]).filter(Boolean).join('');
              resolve(result.trim());
            } else {
              reject(new Error('Unexpected Google response structure'));
            }
          } catch (e) {
            reject(e);
          }
        });
      }).on('error', reject);
    });
  }

  _fetchGoogleWeb(text, from, to) {
    return new Promise((resolve, reject) => {
      const targetLang = to.toLowerCase().startsWith('en') ? 'en' : to;
      const sourceLang = from.toLowerCase().startsWith('zh') ? 'zh-CN' : from;
      const url = `https://translate.google.com/m?sl=${encodeURIComponent(sourceLang)}&tl=${encodeURIComponent(targetLang)}&q=${encodeURIComponent(text)}`;

      const options = {
        headers: {
          'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8'
        },
        timeout: 5000
      };

      https.get(url, options, (res) => {
        if (res.statusCode !== 200) {
          return reject(new Error(`Google Web API status ${res.statusCode}`));
        }

        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => {
          const match = data.match(/class="result-container">([^<]+)<\/div>/);
          if (match && match[1]) {
            const unescaped = match[1]
              .replace(/&amp;/g, '&')
              .replace(/&lt;/g, '<')
              .replace(/&gt;/g, '>')
              .replace(/&quot;/g, '"')
              .replace(/&#39;/g, "'");
            resolve(unescaped.trim());
          } else {
            reject(new Error('Failed to parse Google Web response'));
          }
        });
      }).on('error', reject);
    });
  }
}

module.exports = new TranslationEngine();
