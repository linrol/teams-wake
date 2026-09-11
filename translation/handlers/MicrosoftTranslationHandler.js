const https = require('https');
const BaseTranslationHandler = require('../BaseTranslationHandler');

/**
 * Microsoft Translator (Bing / Edge) handler
 * No API key required, uses dynamic session token rotation
 */
class MicrosoftTranslationHandler extends BaseTranslationHandler {
  constructor() {
    super('microsoft', 'Microsoft Translator (Bing)');
    this.session = null;
    this.sessionExpires = 0;
  }

  async translate(text, from = 'zh-CN', to = 'en') {
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
          this.session = null;
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
              this.session = null;
              reject(new Error('Unexpected Microsoft Translator response format'));
            }
          } catch (e) {
            this.session = null;
            reject(new Error('Microsoft Translator parse error'));
          }
        });
      }).on('error', reject);

      req.write(postData);
      req.end();
    });
  }

  _getBingSession() {
    if (this.session && Date.now() < this.sessionExpires) {
      return Promise.resolve(this.session);
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
          this.session = { ig, iid: iid || 'translator.5025', key, token };
          this.sessionExpires = Date.now() + 3000000; // ~50 minutes
          resolve(this.session);
        });
      }).on('error', reject);
    });
  }
}

module.exports = MicrosoftTranslationHandler;
