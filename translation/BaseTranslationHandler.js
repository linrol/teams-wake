/**
 * Base abstract class for translation handlers
 */
class BaseTranslationHandler {
  constructor(name, displayName) {
    if (!name) {
      throw new Error('Handler name is required');
    }
    this.name = name;
    this.displayName = displayName || name;
  }

  /**
   * Execute translation
   * @param {string} text - Source text
   * @param {string} from - Source language code (e.g. 'zh-CN')
   * @param {string} to - Target language code (e.g. 'en')
   * @returns {Promise<string>} Translated text
   */
  async translate(text, from = 'zh-CN', to = 'en') {
    throw new Error(`Method translate() must be implemented by ${this.constructor.name}`);
  }

  /**
   * Normalize language code for source
   */
  normalizeSourceLang(lang) {
    if (!lang) return 'zh-CN';
    return lang.toLowerCase().startsWith('zh') ? 'zh-CN' : lang;
  }

  /**
   * Normalize language code for target
   */
  normalizeTargetLang(lang) {
    if (!lang) return 'en';
    return lang.toLowerCase().startsWith('en') ? 'en' : lang;
  }
}

module.exports = BaseTranslationHandler;
