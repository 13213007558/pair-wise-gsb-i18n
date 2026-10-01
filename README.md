# Ruby I18n

[![Gem Version](https://badge.fury.io/rb/i18n.svg)](https://badge.fury.io/rb/i18n)
[![Build Status](https://github.com/ruby-i18n/i18n/workflows/Ruby/badge.svg)](https://github.com/ruby-i18n/i18n/actions?query=workflow%3ARuby)

Ruby internationalization and localization (i18n) solution.

Currently maintained by @radar.

## Usage

### Rails

You will most commonly use this library within a Rails app.

We support Rails versions from 6.0 and up.

[See the Rails Guide](https://guides.rubyonrails.org/i18n.html) for an example of its usage.

### Ruby (without Rails)

We support Ruby versions from 3.1 and up.

If you want to use this library without Rails, you can simply add `i18n` to your `Gemfile`:

```ruby
gem 'i18n'
```

Then configure I18n with some translations, and a default locale:

```ruby
I18n.load_path += Dir[File.expand_path("config/locales") + "/*.yml"]
I18n.default_locale = :en # (note that `en` is already the default!)
```

A simple translation file in your project might live at `config/locales/en.yml` and look like:

```yml
en:
  test: "This is a test"
```

You can then access this translation by doing:

```ruby
I18n.t(:test)
```

You can switch locales in your project by setting `I18n.locale` to a different value:

```ruby
I18n.locale = :de
I18n.t(:test) # => "Dies ist ein Test"
```

### Fiber-safe config updates

`Fiber[]` values are inherited by child fibers.
To avoid sharing mutable config objects across fibers, prefer creating updated configs and setting them with `set!`:

```ruby
I18n.config.with(locale: :ja).set!
```

`set!` stores a frozen config in the current execution context.
This keeps inherited state safe and lets updates happen by replacing config objects.

### Pseudo-localization

You can register one or more pseudo locales to check server-rendered pages and
emails for length overflow, encoding issues and hard-coded strings before real
translations are available. Translations for a pseudo locale are resolved from
the source locale (the default locale, unless configured otherwise) and then
transformed: characters are replaced with accented variants, the text is
expanded by a deterministic ratio and wrapped in configurable markers.

```ruby
I18n.backend = I18n::Backend::Simple.new
I18n.backend.extend(I18n::Backend::PseudoLocale)
I18n.config.pseudo_locales = [:ps]
I18n.available_locales = [:en, :ps]

I18n.t('inbox.messages', locale: :ps, count: 2)
# => "⟦2 ɱëššàğëšàçèñ⟧" (pluralization and interpolation still apply)
```

Pluralization and interpolation keep working through the normal I18n flow, and
interpolated user values are never expanded. Interpolation placeholders
(`%{name}`, `%<name>fmt`, `%%`), HTML tags, HTML entities, URLs, email
addresses and business identifiers (e.g. `ORD-12345`) are preserved as-is, so
links and IDs are never rewritten. The transformation is deterministic: the
same template always yields the same output.

The transformation can be tuned through the config:

```ruby
I18n.config.pseudo_expansion_ratio = 0.5        # default: 0.35, 0 disables expansion
I18n.config.pseudo_markers = ['[', ']']         # default: ["⟦", "⟧"]
I18n.config.pseudo_source_locale = :en          # default: the default locale
I18n.config.pseudo_character_map = { 'a' => 'α' } # replaces the default map
I18n.config.pseudo_preserve_patterns = [/ACME-\d+/] # extra tokens to keep verbatim
```

Format fragments that are not understood (e.g. a bare `%d`) are kept verbatim
and reported so they can be inspected:

```ruby
I18n::PseudoLocalizer.unsupported_fragments
# => [{ fragment: "%d", template: "Value: %d units" }]
I18n::PseudoLocalizer.clear_unsupported_fragments
```

## Features

* Translation and localization
* Interpolation of values to translations
* Pluralization (CLDR compatible)
* Customizable transliteration to ASCII
* Flexible defaults
* Bulk lookup
* Lambdas as translation data
* Custom key/scope separator
* Custom exception handlers
* Extensible architecture with a swappable backend

## Pluggable Features

* Cache
* Pluralization: lambda pluralizers stored as translation data
* Locale fallbacks, RFC4647 compliant (optionally: RFC4646 locale validation)
* [Gettext support](https://github.com/ruby-i18n/i18n/wiki/Gettext)
* Translation metadata

## Alternative Backend

* Chain
* ActiveRecord (optionally: ActiveRecord::Missing and ActiveRecord::StoreProcs)
* KeyValue (uses active_support/json and cannot store procs)

For more information and lots of resources see [the 'Resources' page on the wiki](https://github.com/ruby-i18n/i18n/wiki/Resources).

## Tests

You can run tests both with

* `rake test` or just `rake`
* run any test file directly, e.g. `ruby -Ilib:test test/api/simple_test.rb`

You can run all tests against all Gemfiles with

* `ruby test/run_all.rb`

The structure of the test suite is a bit unusual as it uses modules to reuse
particular tests in different test cases.

The reason for this is that we need to enforce the I18n API across various
combinations of extensions. E.g. the Simple backend alone needs to support
the same API as any combination of feature and/or optimization modules included
to the Simple backend. We test this by reusing the same API definition (implemented
as test methods) in test cases with different setups.

You can find the test cases that enforce the API in test/api. And you can find
the API definition test methods in test/api/tests.

All other test cases (e.g. as defined in test/backend, test/core_ext) etc.
follow the usual test setup and should be easy to grok.

## More Documentation

Additional documentation can be found here: https://github.com/ruby-i18n/i18n/wiki

## Contributors

* @radar
* @carlosantoniodasilva
* @josevalim
* @knapo
* @tigrish
* [and many more](https://github.com/ruby-i18n/i18n/graphs/contributors)

## License

MIT License. See the included MIT-LICENSE file.
