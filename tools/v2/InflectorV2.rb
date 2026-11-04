# InflectorV2 — corrected Rails-lite inflection (plan WP6 / defect C5).
#
# Replaces the 3-rule singularizer whose "es" rule mangled regular plurals
# (images -> Imag, messages -> Messag, notes -> Not). Rule table is applied
# in priority order; irregulars first. Validated by tools/v2/test_v2.rb
# against common Rails model names.
module V2
  module Inflector
    IRREGULARS = {
      'people'   => 'person',
      'children' => 'child',
      'men'      => 'man',
      'women'    => 'woman',
      'mice'     => 'mouse',
      'geese'    => 'goose',
      'feet'     => 'foot',
      'teeth'    => 'tooth',
      'criteria' => 'criterion',
      'media'    => 'medium',
      'analyses' => 'analysis',
      'statuses' => 'status',
      'aliases'  => 'alias',
      'quizzes'  => 'quiz',
      'taxes'    => 'tax',
    }.freeze

    # Words that are their own singular (or that Rails leaves alone).
    UNCOUNTABLE = %w[data metadata series species news information equipment].freeze

    module_function

    def singularize(word)
      s = word.to_s
      return s if s.empty? || UNCOUNTABLE.include?(s)
      return IRREGULARS[s] if IRREGULARS.key?(s)

      # ies -> y   (companies -> company, categories -> category)
      return s[0..-4] + 'y'  if s.end_with?('ies') && s.length > 4
      # ives -> ife (lives -> life, knives -> knife)
      return s[0..-4] + 'fe' if s.end_with?('ives') && s.length > 4
      # ves -> f   (leaves -> leaf, halves -> half)
      return s[0..-4] + 'f'  if s.end_with?('ves') && s.length > 4
      # sibilant + es -> strip es (boxes -> box, addresses -> address,
      # branches -> branch, dishes -> dish, buses -> bus)
      if s.end_with?('es') && s.length > 3
        stem = s[0..-3]
        return stem if stem.end_with?('s', 'x', 'z', 'ch', 'sh')
      end
      # plain s -> strip (images -> image, notes -> note, users -> user);
      # guard: not ss (class), not us (status handled above / campus).
      if s.end_with?('s') && s.length > 2 && !s.end_with?('ss', 'us', 'is')
        return s[0..-2]
      end
      s
    end

    # order_items -> OrderItem ; user -> User
    def classify(name)
      name.to_s.split('_').map { |p| p[0].to_s.upcase + p[1..].to_s }.join
    end

    # has_many :order_items -> OrderItem (plural association)
    def classify_plural(name)
      classify(singularize(name.to_s))
    end
  end
end
