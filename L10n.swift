import Foundation

// Язык интерфейса = язык системы: русский, если он первый в списке предпочтений, иначе английский.
let isRussian = Locale.preferredLanguages.first?.hasPrefix("ru") ?? false

/// Строка интерфейса: `t("English", "Русский")`.
@inline(__always) func t(_ en: String, _ ru: String) -> String { isRussian ? ru : en }
