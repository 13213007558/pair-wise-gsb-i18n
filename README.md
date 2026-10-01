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

## Static alias (Symbol link) checker

Translation values that are Symbols act as **links** to other keys and are
resolved at lookup time. Because a link is resolved through the *whole*
backend chain and the *full* locale fallback order, two translation files can
each look perfectly fine on their own yet form a circular alias (or point at
a missing key) only once they are combined. At runtime such a cycle raises
`SystemStackError`.

`I18n::AliasChecker` is a **read-only** static checker that resolves every
Symbol alias exactly the way a real lookup would and reports:

* **circular aliases** – the cycle, every entry point into it and the full
  per-hop chain (backend, locale and file of each link), including cycles
  that only form *across* two backends;
* **dangling aliases** – links whose target key does not exist under the
  backend chain and fallback order;
* **dynamic targets** – aliases that end at a `Proc`; these cannot be
  decided statically and are **never invoked**;
* the **final target type** (`String`, `Hash`, …) and complete resolution
  chain for every healthy alias.

It honours the real query semantics: backend chain priority (a backend's own
fallback locale is searched before moving to the next backend),
`I18n::Locale::Fallbacks` ordering (self, parents, explicit mappings, then
default locales), dotted/mid-namespace links, explicit `nil` falling through
the chain, and Chain namespace merging. It parses files into detached in-memory
hashes: it never instantiates an I18n backend, never touches the translation
cache and never calls a `Proc`.

Run it from the command line with one `--backend` directory per backend in
priority order:

```sh
ruby bin/i18n-alias-check \
  --backend config/locales/app \
  --backend config/locales/gems \
  --fallback-default en          # default; pass "none" to disable
```

Useful options: `--map ca:es-ES` (repeatable explicit fallback mapping),
`-v/--verbose` (also list healthy aliases), `--json` (machine readable).
Exit status is `0` when there are no cycles, dangling aliases or file load
errors, and `1` otherwise.

You can also use the API directly:

```ruby
require 'i18n/alias_checker'

backends, errors = I18n::AliasChecker.load_backends(['config/locales/app',
                                                     'config/locales/gems'])
report = I18n::AliasChecker.analyze(backends, errors,
                                    defaults: [:en],
                                    mappings: { ca: :"es-ES" })
report.cycles     # cross-backend cycles with their entry points and hops
report.danglings  # links to missing keys
report.dynamics   # links that terminate at a Proc
```

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
