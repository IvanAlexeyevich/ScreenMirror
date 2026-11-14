# Установка Screen Mirror с Windows 11

Схема: исходники → macOS runner GitHub Actions → неподписанный device IPA →
локальная подпись Sideloadly → iPhone. Собственный Mac не требуется.
Этот путь подготовлен, но запуск workflow и установка через Sideloadly здесь
не выполнены. Готового подписанного IPA архив не содержит.

1. Распакуйте ScreenMirror-v0.5-Windows.zip. Внутри папки ScreenMirror должны быть
   App, Shared, Broadcast, tools, ScreenMirror.xcodeproj. Это исходники.
2. Создайте аккаунт github.com, затем новый repository ScreenMirror. Public делает
   исходники публичными и позволяет стандартные GitHub Actions runners бесплатно.
   Private сохраняет код закрытым, но действует лимит минут/условия биллинга.
   Можно отметить Add README для создания main. Apple credentials не нужны.
3. В репозитории выберите Add file → Upload files. Загрузите содержимое папки
   ScreenMirror, не саму папку целиком. App и ScreenMirror.xcodeproj должны оказаться
   в корне репозитория. Нажмите Commit changes.
4. Убедитесь, что присутствует .github/workflows/build-iphone-ipa.yml. Если скрытая
   папка не загрузилась: Add file → Create new file; в имя впишите этот путь, а в
   редактор скопируйте содержимое готового build-iphone-ipa.yml из архива. Commit.
5. Actions → Build iPhone IPA (Windows installation) → Run workflow. В bundle_id
   задайте уникальный ID, например com.nikita.screenmirror. Сохраните это значение:
   для будущих обновлений ID должен оставаться тем же. Нажмите Run workflow.
   Если GitHub предложит включить Actions, разрешите запуск в своём repository.
6. Откройте новый запуск и дождитесь зелёной галочки. При красной откройте упавший
   шаг и пришлите текст ошибки. До успешного Build IPA установить нечего.
7. Внизу успешного запуска в Artifacts скачайте ScreenMirror-iPhone-unsigned.
   GitHub выдаст ZIP. Распакуйте его: нужен ScreenMirror-unsigned.ipa.
   Сам IPA распаковывать не нужно. Workflow проверяет iphoneos, arm64 и наличие
   PlugIns/Broadcast.appex: сборка симулятора для установки не подходит.
8. Откройте https://sideloadly.io/ и установите Windows 64-bit версию. По текущим
   требованиям Sideloadly нужны web-версии iTunes и iCloud с сайта Apple, не версии
   Microsoft Store. Используйте ссылки Before you install на официальной странице.
   Если стоят Store-версии iTunes/iCloud, следуйте инструкции Sideloadly об их замене.
9. Подключите iPhone кабелем, разблокируйте и подтвердите «Доверять компьютеру».
   Убедитесь, что iTunes видит телефон. Откройте Sideloadly, выберите iPhone и
   перетащите в него ScreenMirror-unsigned.ipa.
10. Укажите свой Apple ID. Подпись — обычная Apple ID sideload. Сохраните расширения:
    не включайте Remove Extensions / Remove PlugIns. Без Broadcast.appex приложение
    откроется, но системная трансляция экрана не заработает. Не меняйте Bundle ID
    между обновлениями. Нажмите Start и вводите пароль/2FA только в Sideloadly.
    Для бесплатного аккаунта не подменяйте обычный пароль app-specific password:
    FAQ Sideloadly ограничивает поддержку app-specific паролей платным аккаунтом
    и определённым режимом anisette. Пароли/коды не нужны GitHub и этому чату.
11. После установки, если iOS требует: Settings → General → VPN & Device Management
    → профиль Apple ID → Trust. Developer Mode: Settings → Privacy & Security →
    Developer Mode → включить и подтвердить после перезагрузки. Если режим уже
    включён после Xcode, повторять не нужно.
12. Запустите Screen Mirror и проверьте версию 0.5.0 (8), разрешите Local Network.
    Сначала «Найти телевизор». Если поиска нет, один раз сохраните известный URL
    http://192.168.31.30:7676/smp_37_ — это адрес из предыдущего испытания, он мог
    измениться. После сохранения повторный ввод не нужен.

Обновление поверх приложения друга: необходимы совместимые Bundle ID и Apple
signing team. Если первая установка была подписана другим Apple ID, iOS может
отказать обновлению. Не удаляйте рабочее приложение заранее. При отказе пришлите
лог. Возможные варианты — отдельный Bundle ID (вторая копия) или удаление старой
копии перед установкой новой; при удалении её данные теряются.

Бесплатная подпись обычно 7 дней. Повторно собирать IPA еженедельно не нужно:
Sideloadly переподписывает тот же IPA тем же Apple ID. Можно включить Auto Refresh
и держать его помощник работающим на Windows. Для Wi-Fi refresh сначала включите
в iTunes Sync with this iPhone over Wi-Fi и примените настройки. ПК должен быть
доступен телефону; USB — запасной путь. Если обновление не произошло, приложение
перестаёт запускаться до новой подписи. Не меняйте ID каждую неделю: есть лимиты
бесплатных app IDs и числа установленных приложений.

Частые проблемы:

- workflow не виден: неверный путь .github/workflows/… или файлы лежат на уровень глубже.
- красный GitHub job: открыть упавший шаг, скопировать его ошибку; не пытаться ставить
  simulator artifact или ZIP исходников.
- Sideloadly не видит телефон: проверить кабель, доверие, видимость в iTunes и drivers.
- кнопка трансляции не предлагает Screen Mirror: проверить, что расширение не удалено.
- ошибка provisioning / лимита IDs: нужен точный лог, это не ошибка телевизора.
- подпись друга отличается: не менять/удалять данные наугад; сначала проверить лог.

Проверенные источники 14.11.2026:
https://sideloadly.io/
https://sideloadly.io/faq
https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-actions/about-billing-for-github-actions
