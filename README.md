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

## Transliteration

I18n maps UTF-8 characters to an ASCII approximation, using a hash of
character rules, a proc, or declarative multi-character rules:

```ruby
I18n::Backend::Transliterator.get.transliterate("Ærøskøbing")
# => "AEroskobing"

I18n.transliterate("Jürgen") # => "Jurgen"
```

You can override a locale's rule with a Hash (single characters), a Proc
or a list of declarative `I18n::Backend::Transliterator::Rule` objects:

```ruby
rule = I18n::Backend::Transliterator::Rule
I18n.backend.store_translations(:de, :i18n => { :transliterate => { :rule => [
  rule.new(:from => "ü", :to => "ue"),
  # digraph: both characters together become one syllable
  rule.new(:from => "sch", :to => "sh", :match_ascii => true),
  # contexts may be Strings or Regexps (word boundary, lookbehind, ...)
  rule.new(:from => "ch", :to => "k", :match_ascii => true, :right => /\b/),
  # equal-length overlaps are disambiguated by priority (then definition order)
  rule.new(:from => "ae", :to => "E", :priority => 10, :match_ascii => true)
] } })
```

Declarative rules support:

* multi-character `from` input and arbitrary `to` output (including `""`);
* finite `left` and `right` contexts given as Strings or Regexps;
* integer `priority` for overlapping rules (higher wins, default `0`);
* longest valid match by default, then priority, then definition order;
* matching under an explicit Unicode normalization form (NFC by default,
  pass `normalization_form: :nfd|:nfkc|:nfkd` to `Transliterator.get`),
  so decomposed input like `u` + combining diaeresis matches `ü`;
* inheritance of the default Latin => ASCII approximations, overridable
  per rule.

Pure ASCII sequences only match when a rule sets `match_ascii: true`.
The engine performs a single left-to-right scan and never feeds
transliterated output back through the rules, so the same input always
yields the same result.

`transliterate_with_ranges` additionally returns each output fragment
together with the codepoint range it occupied in the original input:

```ruby
t = I18n::Backend::Transliterator.get(rule.new(:from => "ü", :to => "ue"))
t.transliterate_with_ranges("hübsch")
# => [["h", 0...1], ["ue", 1...2], ["b", 2...3], ...]
```

Characters without a rule keep using the `replacement` option
(default `"?"`, or `:none` to keep them unchanged).

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
