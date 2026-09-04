/// Адрес сервера. Для эмулятора Android 10.0.2.2 = «этот компьютер».
/// Позже вынесем в настройки; пока одно место.
const String apiBaseUrl = String.fromEnvironment(
  'SOUNDFLOW_API',
  defaultValue: 'http://10.0.2.2:8090',
);
