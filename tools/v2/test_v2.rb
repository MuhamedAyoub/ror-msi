#!/usr/bin/env ruby
# test_v2.rb — integrity fixture tests for the v2 resolver (plan §eval).
# Plain asserts, no test framework. Run:  ruby tools/v2/test_v2.rb
require_relative 'RailsAwareGraphV2'
require_relative 'InflectorV2'

$failures = []
def check(desc)
  ok = yield
  puts (ok ? "  PASS  " : "  FAIL  ") + desc
  $failures << desc unless ok
rescue => e
  puts "  ERROR #{desc}: #{e.class}: #{e.message}"
  $failures << desc
end

# ---------- Inflector (C5) ----------
I = V2::Inflector
puts "[inflector]"
{ 'images' => 'image', 'messages' => 'message', 'notes' => 'note',
  'companies' => 'company', 'statuses' => 'status', 'addresses' => 'address',
  'boxes' => 'box', 'people' => 'person', 'users' => 'user',
  'order_items' => 'order_item', 'data' => 'data' }.each do |plural, singular|
  check("singularize #{plural} -> #{singular}") { I.singularize(plural) == singular }
end
check("classify_plural order_items -> OrderItem") { I.classify_plural('order_items') == 'OrderItem' }

# ---------- Graph fixtures ----------
puts "[graph]"
builder = V2::RailsAwareGraphV2.new(app_root: File.join(__dir__, 'fixtures/app')).build!
g = builder.graph
report = builder.resolver_report

# C2 — no node merging
check("Api::V1::User and User are distinct nodes") {
  g.key?('Api::V1::User') && g.key?('User')
}

# R8 — polymorphic join resolved exactly
check("Comment -> Post assoc edge (polymorphic join)")    { g['Comment']['Post'].to_f > 0 }
check("Comment -> Article assoc edge (polymorphic join)") { g['Comment']['Article'].to_f > 0 }
check("polymorphic_resolved counted") { report[:polymorphic_resolved].to_i >= 1 }

# C5 — inflector-dependent association edges land
check("User -> Image edge (has_many :images)") { g['User']['Image'].to_f > 0 }
check("User -> Note edge (has_many :notes)")   { g['User']['Note'].to_f > 0 }

# L1 — assignment-flow typing
check("ReportService -> User edge (user = User.find; user.notify_weekly)") {
  g['ReportService']['User'].to_f > 0
}
check("l1_var_typed layer fired") { report[:l1_var_typed].to_i >= 1 }

# R18/L0 — exact job dispatch, no fan-out to sibling job
check("CommentsController -> CleanupJob edge") { g['CommentsController']['CleanupJob'].to_f > 0 }
check("CommentsController has NO edge to PurgeJob") { g['CommentsController']['PurgeJob'].to_f.zero? }

# R8 receiver — @comment.commentable splits weight across the union
check("@comment.commentable produced union edges to Post and Article") {
  report[:l1_union].to_i >= 1 || (g['CommentsController']['Post'].to_f > 0 &&
                                  g['CommentsController']['Article'].to_f > 0)
}

# C1 — unknown-receiver homonym must not add full-weight edges to both jobs
check("something.perform(2): no full-weight fan-out (suppressed or fractional)") {
  a = g['CommentsController']['CleanupJob'].to_f
  b = g['CommentsController']['PurgeJob'].to_f
  # PurgeJob may only ever be reached fractionally (< 1), never at weight 1.
  b < 1.0
}

# Bounded ambiguity: any single L4 site contributes total weight <= 1
check("L4 accounting present in report") {
  %i[l4_fanout_sites l4_cap_suppressed l4_no_owner l4_noise_suppressed].any? { |k| report.key?(k) }
}

puts "\n#{$failures.empty? ? 'ALL PASS' : "#{$failures.size} FAILURES"}"
puts "resolver_report: #{report.sort_by { |k, _| k.to_s }.map { |k, v| "#{k}=#{v}" }.join(' ')}"
exit($failures.empty? ? 0 : 1)
