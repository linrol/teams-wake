const MicrosoftTranslationHandler = require('./handlers/MicrosoftTranslationHandler');
const GoogleTranslationHandler = require('./handlers/GoogleTranslationHandler');

/**
 * Translation Engine / Manager
 * Manages handlers, fallback chain, and LRU translation cache
 */
class TranslationEngine {
  constructor() {
    this.handlers = new Map();
    this.provider = 'microsoft';
    this.cache = new Map();
    this.maxCacheSize = 300;

    // Register built-in default handlers
    this.registerHandler(new MicrosoftTranslationHandler());
    this.registerHandler(new GoogleTranslationHandler());
  }

  /**
   * Register a new translation handler/processor
   * @param {BaseTranslationHandler} handler 
   */
  registerHandler(handler) {
    if (!handler || !handler.name) {
      throw new Error('Invalid translation handler');
    }
    this.handlers.set(handler.name, handler);
  }

  /**
   * Get all registered providers
   * @returns {Array<{ name: string, displayName: string }>}
   */
  getProviders() {
    return Array.from(this.handlers.values()).map(h => ({
      name: h.name,
      displayName: h.displayName
    }));
  }

  /**
   * Set active translation provider
   * @param {string} providerName 
   */
  setProvider(providerName) {
    if (this.handlers.has(providerName)) {
      this.provider = providerName;
    } else {
      console.warn(`[TranslationEngine] Provider "${providerName}" not registered, keeping "${this.provider}"`);
    }
  }

  /**
   * Get current active provider name
   * @returns {string}
   */
  getProvider() {
    return this.provider;
  }

  /**
   * Get handler instance by name
   * @param {string} [name] 
   * @returns {BaseTranslationHandler|null}
   */
  getHandler(name = this.provider) {
    return this.handlers.get(name) || null;
  }

  /**
   * Translate text with automatic multi-engine failover and LRU caching
   * @param {string} text 
   * @param {string} from 
   * @param {string} to 
   * @returns {Promise<string>}
   */
  async translate(text, from = 'zh-CN', to = 'en') {
    if (!text || !text.trim()) return '';
    const trimmed = text.trim();
    const cacheKey = `${from}:${to}:${trimmed}`;

    if (this.cache.has(cacheKey)) {
      return this.cache.get(cacheKey);
    }

    const primaryHandler = this.getHandler(this.provider);
    if (!primaryHandler) {
      throw new Error(`Primary translation handler "${this.provider}" not found`);
    }

    let result = '';
    try {
      result = await primaryHandler.translate(trimmed, from, to);
    } catch (primaryErr) {
      // Find candidate secondary handlers for fallback
      const secondaryHandlers = Array.from(this.handlers.values()).filter(h => h.name !== this.provider);
      let fallbackSuccess = false;
      let lastErr = primaryErr;

      for (const fallbackHandler of secondaryHandlers) {
        console.warn(`[TranslationEngine] Primary (${this.provider}) failed: ${primaryErr.message}. Trying fallback to ${fallbackHandler.displayName}...`);
        try {
          result = await fallbackHandler.translate(trimmed, from, to);
          fallbackSuccess = true;
          break;
        } catch (secondaryErr) {
          lastErr = secondaryErr;
        }
      }

      if (!fallbackSuccess) {
        throw new Error(`All translation engines failed. Primary (${this.provider}): ${primaryErr.message} | Last fallback: ${lastErr.message}`);
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
}

// Export singleton instance as well as classes
const engineInstance = new TranslationEngine();
engineInstance.TranslationEngine = TranslationEngine;
module.exports = engineInstance;
