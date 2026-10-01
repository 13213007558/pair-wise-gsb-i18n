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

## Static alias (link) checking

Translation values that are Symbols are links to other keys (see
`I18n::Backend::Base#resolve`). Because links are followed lazily at lookup
time, mistakes only surface at runtime: links can form infinite cycles, point
at keys that do not exist (dangling references), or resolve to unexpected
value types. A cycle can be invisible while reviewing files individually,
because it only closes once a query crosses two backends of a backend chain
(possibly across locale fallbacks).

`I18n::Backend::AliasChecker` is a *read-only, static* checker. It loads
translation files into throwaway, in-memory data and simulates a real query
exactly — backend chain priority (with leftmost-wins namespace merges), the
absolute-key scope semantics of links, and the locale fallback order (every
alias hop restarts from the originally requested locale). Dynamic values
(Procs) are reported as such and are never called, and `I18n.backend`,
`I18n.config`, `I18n.load_path`, the fallbacks global and translation caches
are never modified.

```ruby
require 'i18n/backend/alias_checker'

checker = I18n::Backend::AliasChecker.new(
  backend_dirs:   [['config/locales'], ['engines/blog/config/locales']], # chain order
  default_locales: [:en],
  fallback_mapping: { :"de-AT" => :de }
)

checker.check.each do |finding|
  finding.results.each do |result|
    next if result.status == :ok
    puts "#{result.status}: #{finding.alias_key} (locale #{result.locale})"
    result.hops.each { |hop| puts "  #{hop}" }
  end
end
checker.healthy? # => false if any cycle or dangling link was found
```

A CLI ships with the gem:

```sh
ruby -Ilib bin/i18n-alias-check \
  --backend config/locales \
  --backend engines/blog/config/locales \
  --default-locale en --map de-AT=de --all
```

It prints the status and complete resolution chain of every alias (text or
`--json`) and exits non-zero when a cycle or dangling reference is found, so
it can gate releases.

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
