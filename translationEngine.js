const https = require('https');

class TranslationEngine {
  async translate(text, from = 'zh-CN', to = 'en') {
    if (!text || !text.trim()) return '';
    return await this._fetchGoogle(text, from, to);
  }

  _fetchGoogle(text, from, to) {
    return new Promise((resolve, reject) => {
      const targetLang = to.toLowerCase().startsWith('en') ? 'en' : to;
      const sourceLang = from.toLowerCase().startsWith('zh') ? 'zh-CN' : from;
      const url = `https://translate.googleapis.com/translate_a/single?client=gtx&sl=${encodeURIComponent(sourceLang)}&tl=${encodeURIComponent(targetLang)}&dt=t&q=${encodeURIComponent(text)}`;

      https.get(url, { timeout: 5000 }, (res) => {
        if (res.statusCode !== 200) {
          return reject(new Error(`Google API status ${res.statusCode}`));
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
}

module.exports = new TranslationEngine();

