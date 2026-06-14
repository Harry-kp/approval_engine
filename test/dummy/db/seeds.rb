# Demo seed for the dummy app — builds a small, live approval track you can
# explore in the console or watch in the dashboard. Safe to re-run.
#
#   bin/rails app:db:seed          # from the engine root
#   bin/console  -> Rails.application.load_seed
TENANT = "demo".freeze

puts "Resetting demo data…"
[ ApprovalEngine::AuditLog, ApprovalEngine::OutboxEvent, ApprovalEngine::Step,
  ApprovalEngine::Track, ApprovalEngine::Approval, ApprovalEngine::TriggerRule,
  ApprovalEngine::TemplateStep, ApprovalEngine::TrackTemplate,
  ApprovalEngine::Delegation, Invoice, User ].each(&:delete_all)

ApprovalEngine.configure { |c| c.actor_class = "User" }

manager = User.create!(name: "Maria (Manager)", role: "manager")
cfo     = User.create!(name: "Carl (CFO)", role: "cfo")

template = ApprovalEngine::TrackTemplate.create!(
  tenant_id: TENANT, name: "High-value invoice", status: "active"
)
template.template_steps.create!(name: "Manager sign-off", layer: 1, assigned_group: "manager")
template.template_steps.create!(name: "CFO sign-off",     layer: 2, assigned_group: "cfo")

template.trigger_rules.create!(
  tenant_id: TENANT, event_name: "invoice.created",
  condition: { ">" => [ { "var" => "amount" }, 1000 ] }
)

invoice  = Invoice.create!(tenant_id: TENANT, amount: 6000, department: "IT")
approval = invoice.run_approval!(event: "invoice.created", tenant_id: TENANT)

puts <<~SUMMARY

  Seeded a live approval:
    Invoice ##{invoice.id} ($#{invoice.amount}) → Approval ##{approval.id} (#{approval.status})
    Pending now: #{approval.steps.pending.map(&:name).join(", ")}

  Try it in the console:
    step = ApprovalEngine::Step.pending.first
    step.approve!(by: User.find_by(role: "manager"))   # advances to the CFO
    ApprovalEngine::Step.pending.first.approve!(by: User.find_by(role: "cfo"))

  Or watch it in the dashboard:
    cd test/dummy && bin/rails server  →  http://localhost:3000/approval_engine
SUMMARY
