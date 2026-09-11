const https = require('https');
const BaseTranslationHandler = require('../BaseTranslationHandler');

/**
 * Google Translate handler
 * Multi-channel fallback: Chrome Extension API -> GTX Endpoint -> Mobile Web
 */
class GoogleTranslationHandler extends BaseTranslationHandler {
  constructor() {
    super('google', 'Google Translate');
  }

  async translate(text, from = 'zh-CN', to = 'en') {
    try {
      return await this._fetchChromeEx(text, from, to);
    } catch (err1) {
      try {
        return await this._fetchGtx(text, from, to);
      } catch (err2) {
        return await this._fetchWeb(text, from, to);
      }
    }
  }

  _fetchChromeEx(text, from, to) {
    return new Promise((resolve, reject) => {
      const targetLang = this.normalizeTargetLang(to);
      const sourceLang = this.normalizeSourceLang(from);
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

  _fetchGtx(text, from, to) {
    return new Promise((resolve, reject) => {
      const targetLang = this.normalizeTargetLang(to);
      const sourceLang = this.normalizeSourceLang(from);
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

  _fetchWeb(text, from, to) {
    return new Promise((resolve, reject) => {
      const targetLang = this.normalizeTargetLang(to);
      const sourceLang = this.normalizeSourceLang(from);
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

module.exports = GoogleTranslationHandler;
