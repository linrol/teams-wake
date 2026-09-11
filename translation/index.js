const BaseTranslationHandler = require('./BaseTranslationHandler');
const MicrosoftTranslationHandler = require('./handlers/MicrosoftTranslationHandler');
const GoogleTranslationHandler = require('./handlers/GoogleTranslationHandler');
const translationEngine = require('./TranslationEngine');

module.exports = {
  BaseTranslationHandler,
  MicrosoftTranslationHandler,
  GoogleTranslationHandler,
  translationEngine,
  TranslationEngine: translationEngine.TranslationEngine
};
