# Demo seed for the dummy app — a small but *lived-in* set of approvals you can
# explore in the console or watch in the dashboard. Safe to re-run.
#
#   bin/rails app:db:seed          # from the engine root
#   bin/console  -> Rails.application.load_seed
#
# It deliberately seeds finished work as well as pending work. A single freshly
# created approval shows an empty audit trail, which is the least interesting
# thing this engine does; the point of the ledger is what it remembers.
TENANT = "demo".freeze

puts "Resetting demo data…"
[ ApprovalEngine::AuditLog, ApprovalEngine::OutboxEvent, ApprovalEngine::Step,
  ApprovalEngine::Track, ApprovalEngine::Approval, ApprovalEngine::TriggerRule,
  ApprovalEngine::TemplateStep, ApprovalEngine::TrackTemplate,
  ApprovalEngine::Delegation, Invoice, User ].each(&:delete_all)

ApprovalEngine.configure { |c| c.actor_class = "User" }

manager = User.create!(name: "Maria Okonkwo",  role: "manager", email: "maria@example.com")
cfo     = User.create!(name: "Carl Jensen",    role: "cfo",     email: "carl@example.com")
legal   = User.create!(name: "Lena Petrova",   role: "legal",   email: "lena@example.com")
it_lead = User.create!(name: "Ivan Torres",    role: "it",      email: "ivan@example.com")

# One block instead of a template, two steps and a hand-written JSON Logic rule.
# It reconciles rather than inserts, so this is safe on every deploy — the reset
# above is only here to make the demo output deterministic.
ApprovalEngine.define_flow "High-value invoice", tenant: TENANT, model: Invoice do
  on :create, when: { amount: { gt: 1_000 } }
  step "Manager sign-off", group: "manager"
  step "CFO sign-off",     group: "cfo"
end

# The same idea one size up: Legal and IT review at the same time, and both must
# sign off before it reaches the CFO. This is the shape that is genuinely tedious
# to hand-roll, so the demo should show it.
ApprovalEngine.define_flow "Major capital spend", tenant: TENANT, model: Invoice do
  on :create, when: { amount: { gt: 100_000 } }, priority: 10
  step "Manager sign-off", group: "manager"
  parallel(approvals_required: :all) do
    step "Legal review", group: "legal"
    step "IT review",    group: "it"
  end
  step "CFO sign-off", group: "cfo"
end

def raise_invoice(amount, department)
  invoice = Invoice.create!(tenant_id: TENANT, amount: amount, department: department)
  [ invoice, invoice.run_approval!(event: "invoice.created", tenant_id: TENANT) ]
end

def pending_step(approval, name)
  approval.steps.reload.pending.find { |step| step.name == name }
end

# 1. Untouched — sitting in Maria's inbox right now.
raise_invoice(6_000, "IT")

# 2. Half-done — Maria signed, so it is Carl's turn and the trail has history.
_, waiting_on_cfo = raise_invoice(12_000, "Marketing")
pending_step(waiting_on_cfo, "Manager sign-off").approve!(by: manager, comment: "Budgeted for Q3.")

# 3. Finished — the full trail, end to end, and the invoice marked paid by the
#    host's own after_approved callback.
_, approved = raise_invoice(8_500, "Sales")
pending_step(approved, "Manager sign-off").approve!(by: manager)
pending_step(approved, "CFO sign-off").approve!(by: cfo, comment: "Approved against the annual plan.")

# 4. Rejected at the last step, which is the case people most want to audit.
_, rejected = raise_invoice(25_000, "Operations")
pending_step(rejected, "Manager sign-off").approve!(by: manager)
pending_step(rejected, "CFO sign-off").reject!(by: cfo, comment: "No PO on file — resubmit with one.")

# 5. Sent back for rework. Requesting changes appends a second iteration rather
#    than editing the first, so the ledger still shows what happened the first
#    time round.
_, reworked = raise_invoice(40_000, "Engineering")
pending_step(reworked, "Manager sign-off").request_changes!(by: manager, comment: "Split this across two POs.")

# 6. Mid-scatter — Legal and IT are both holding it, neither has moved.
_, capital = raise_invoice(150_000, "Facilities")
pending_step(capital, "Manager sign-off").approve!(by: manager, comment: "Board approved the capex line.")

counts = ApprovalEngine::Approval.group(:status).count

puts <<~SUMMARY

  Seeded #{ApprovalEngine::Approval.count} approvals across #{counts.size} states:
    #{counts.map { |status, n| "#{n} #{status}" }.join(", ")}

  Waiting on someone right now:
    #{ApprovalEngine::Step.pending.map { |s| "#{s.name} → #{s.assigned_actor&.name}" }.uniq.join("\n  ")}

  Try it in the console:
    step = ApprovalEngine::Step.actionable_by(User.find_by(role: "legal")).first
    step.approve!(by: User.find_by(role: "legal"))     # Legal signs; IT still holds it

  Or watch it in the dashboard:
    cd test/dummy && bin/rails server  →  http://localhost:3000/approval_engine
SUMMARY
