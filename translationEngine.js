const https = require('https');

class TranslationEngine {
  constructor() {
    this.provider = 'microsoft'; // 'microsoft' | 'google'
    this.cache = new Map();
    this.maxCacheSize = 300;

    // Microsoft Bing session cache
    this.bingSession = null;
    this.bingSessionExpires = 0;
  }

  setProvider(provider) {
    if (provider === 'google' || provider === 'microsoft') {
      this.provider = provider;
    }
  }

  getProvider() {
    return this.provider;
  }

  async translate(text, from = 'zh-CN', to = 'en') {
    if (!text || !text.trim()) return '';
    const trimmed = text.trim();
    const cacheKey = `${from}:${to}:${trimmed}`;

    if (this.cache.has(cacheKey)) {
      return this.cache.get(cacheKey);
    }

    let result = '';
    const primary = this.provider;
    const secondary = primary === 'microsoft' ? 'google' : 'microsoft';

    try {
      if (primary === 'microsoft') {
        result = await this._translateMicrosoft(trimmed, from, to);
      } else {
        result = await this._translateGoogle(trimmed, from, to);
      }
    } catch (primaryErr) {
      console.warn(`[TranslationEngine] Primary provider (${primary}) failed: ${primaryErr.message}. Falling back to ${secondary}...`);
      try {
        if (secondary === 'microsoft') {
          result = await this._translateMicrosoft(trimmed, from, to);
        } else {
          result = await this._translateGoogle(trimmed, from, to);
        }
      } catch (secondaryErr) {
        throw new Error(`Translation failed on both providers: ${primaryErr.message} | ${secondaryErr.message}`);
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

  /* -------------------------------------------------------------
     Microsoft Bing / Edge Translator Implementation (Zero Key)
  ------------------------------------------------------------- */
  async _translateMicrosoft(text, from = 'zh-CN', to = 'en') {
    const fromLang = from.toLowerCase().startsWith('zh') ? 'zh-Hans' : from;
    const targetLang = to.toLowerCase().startsWith('en') ? 'en' : to;
    const session = await this._getBingSession();

    return new Promise((resolve, reject) => {
      const postData = new URLSearchParams({
        fromLang: fromLang,
        text: text,
        to: targetLang,
        token: session.token,
        key: session.key
      }).toString();

      const url = `https://www.bing.com/ttranslatev3?isVertical=1&&IG=${session.ig}&IID=${session.iid}`;
      const req = https.request(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Content-Length': Buffer.byteLength(postData),
          'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
          'Referer': 'https://www.bing.com/translator'
        },
        timeout: 5000
      }, (res) => {
        if (res.statusCode !== 200) {
          // Clear session cache on auth failure so next call refreshes tokens
          this.bingSession = null;
          return reject(new Error(`Microsoft Bing HTTP ${res.statusCode}`));
        }

        let data = '';
        res.on('data', c => data += c);
        res.on('end', () => {
          try {
            const json = JSON.parse(data);
            if (json && json[0] && json[0].translations && json[0].translations[0]) {
              resolve(json[0].translations[0].text.trim());
            } else {
              this.bingSession = null;
              reject(new Error('Unexpected Microsoft Translator response format'));
            }
          } catch (e) {
            this.bingSession = null;
            reject(new Error('Microsoft Translator parse error'));
          }
        });
      }).on('error', reject);

      req.write(postData);
      req.end();
    });
  }

  _getBingSession() {
    if (this.bingSession && Date.now() < this.bingSessionExpires) {
      return Promise.resolve(this.bingSession);
    }

    return new Promise((resolve, reject) => {
      https.get('https://www.bing.com/translator', {
        headers: {
          'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
        },
        timeout: 5000
      }, (res) => {
        let html = '';
        res.on('data', c => html += c);
        res.on('end', () => {
          const ig = (html.match(/IG:"([^"]+)"/) || [])[1];
          const iid = (html.match(/data-iid="([^"]+)"/) || [])[1];
          const paramsMatch = (html.match(/params_AbusePreventionHelper\s*=\s*\[([^\]]+)\]/) || [])[1];
          if (!ig || !paramsMatch) {
            return reject(new Error('Failed to extract Microsoft Translator session tokens'));
          }
          const [key, token] = paramsMatch.split(',').map(s => s.trim().replace(/^"|"$/g, ''));
          this.bingSession = { ig, iid: iid || 'translator.5025', key, token };
          this.bingSessionExpires = Date.now() + 3000000; // ~50 minutes
          resolve(this.bingSession);
        });
      }).on('error', reject);
    });
  }

  /* -------------------------------------------------------------
     Google Translate Multi-Channel Implementation (Zero Key)
  ------------------------------------------------------------- */
  async _translateGoogle(text, from = 'zh-CN', to = 'en') {
    try {
      return await this._fetchGoogleChromeEx(text, from, to);
    } catch (err1) {
      try {
        return await this._fetchGoogleGtx(text, from, to);
      } catch (err2) {
        return await this._fetchGoogleWeb(text, from, to);
      }
    }
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
