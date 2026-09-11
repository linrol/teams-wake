const https = require('https');
const BaseTranslationHandler = require('../BaseTranslationHandler');

/**
 * Microsoft Translator Handler (Optimized for ultra-low latency)
 * Channel 1 (Primary): Direct Microsoft Edge Browser Translation Service (~200ms, Keep-Alive, Zero Key)
 * Channel 2 (Fallback): Bing Web Translator API with token rotation
 */
class MicrosoftTranslationHandler extends BaseTranslationHandler {
  constructor() {
    super('microsoft', 'Microsoft Translator (Edge / Bing)');
    this.agent = new https.Agent({
      keepAlive: true,
      maxSockets: 10,
      keepAliveMsecs: 60000
    });
    this.session = null;
    this.sessionExpires = 0;
  }

  async translate(text, from = 'zh-CN', to = 'en') {
    const fromLang = from.toLowerCase().startsWith('zh') ? 'zh-Hans' : (from.toLowerCase().startsWith('en') ? 'en' : from);
    const targetLang = to.toLowerCase().startsWith('zh') ? 'zh-Hans' : (to.toLowerCase().startsWith('en') ? 'en' : to);

    // Channel 1: Edge Browser Internal API (Fastest: ~180-400ms, no token needed)
    try {
      return await this._translateEdge(text, fromLang, targetLang);
    } catch (edgeErr) {
      console.warn(`[MicrosoftTranslationHandler] Edge API failed (${edgeErr.message}), falling back to Bing Web...`);
      // Channel 2: Bing Web Translator Fallback
      return await this._translateBingWeb(text, fromLang, targetLang);
    }
  }

  /* -------------------------------------------------------------
     Channel 1: Edge Browser Direct Translation (Ultra Fast)
  ------------------------------------------------------------- */
  _translateEdge(text, fromLang, targetLang) {
    return new Promise((resolve, reject) => {
      const postData = JSON.stringify([text]);
      const url = `https://edge.microsoft.com/translate/translatetext?from=${encodeURIComponent(fromLang)}&to=${encodeURIComponent(targetLang)}&isEnterpriseClient=false`;

      const req = https.request(url, {
        method: 'POST',
        agent: this.agent,
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(postData),
          'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0',
          'Referer': 'https://edge.microsoft.com'
        },
        timeout: 4000
      }, (res) => {
        if (res.statusCode !== 200) {
          return reject(new Error(`Edge Translator HTTP ${res.statusCode}`));
        }

        let data = '';
        res.on('data', chunk => data += chunk);
        res.on('end', () => {
          try {
            const json = JSON.parse(data);
            if (Array.isArray(json) && json[0] && json[0].translations && json[0].translations[0]) {
              resolve(json[0].translations[0].text.trim());
            } else {
              reject(new Error('Unexpected Edge Translator response format'));
            }
          } catch (e) {
            reject(new Error('Edge Translator parse error'));
          }
        });
      });

      req.on('error', reject);
      req.write(postData);
      req.end();
    });
  }

  /* -------------------------------------------------------------
     Channel 2: Bing Web Translation (Backup with Session Token)
  ------------------------------------------------------------- */
  async _translateBingWeb(text, fromLang, targetLang) {
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
        agent: this.agent,
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
              reject(new Error('Unexpected Bing Web Translator response format'));
            }
          } catch (e) {
            this.session = null;
            reject(new Error('Bing Web Translator parse error'));
          }
        });
      });

      req.on('error', reject);
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
        agent: this.agent,
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
