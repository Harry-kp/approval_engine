require "test_helper"

module ApprovalEngine
  # The notifications themselves. The invariant every one of these defends: a
  # template may only read the plain Strings the mailer precomputed, so the same
  # six emails work in an app whose record has no `name`, no `title`, and a
  # default Object#to_s.
  class NotificationMailerTest < ApprovalEngine::TestCase
    setup do
      @invoice  = Invoice.create!(tenant_id: TENANT, amount: 6000)
      @manager  = create_user(role: :manager, email: "manager@example.test")
      @approval = Approval.create!(tenant_id: TENANT, target: @invoice, status: "pending", event_name: "invoice.created")
      @track    = @approval.tracks.create!(tenant_id: TENANT, name: "Finance")
      @step     = @track.steps.create!(tenant_id: TENANT, name: "Manager sign-off", layer: 1,
                                       status: "pending", assigned_actor: @manager)
    end

    def activated
      NotificationMailer.step_activated(@step, to: "manager@example.test")
    end

    def body_of(mail, format)
      mail.parts.find { |part| part.content_type.start_with?("text/#{format}") }.body.to_s
    end

    test "step_activated names the target and the approver without touching the host model" do
      mail = activated

      assert_equal "Approval needed: Invoice ##{@invoice.id}", mail.subject
      assert_equal [ "manager@example.test" ], mail.to
      assert_match(/Manager/, body_of(mail, :plain), "the approver is greeted by name")
    end

    test "it renders both a text and an html part" do
      mail = activated

      assert mail.multipart?
      assert_equal 2, mail.parts.size
      assert_match(/Invoice ##{@invoice.id}/, body_of(mail, :plain))
      assert_match(/Invoice ##{@invoice.id}/, body_of(mail, :html))
    end

    test "the label falls back to class and id when the host configures nothing" do
      mail = activated

      assert_match(/Invoice #/, mail.subject)
      mail.parts.each do |part|
        assert_no_match(/#<Invoice/, part.body.to_s, "no view may call to_s on a host record")
      end
    end

    test "target_label_method lets a host name its own record" do
      ApprovalEngine.config.target_label_method = :reference
      Invoice.define_method(:reference) { "INV-4711" }

      assert_equal "Approval needed: INV-4711", activated.subject
    ensure
      Invoice.remove_method(:reference) if Invoice.method_defined?(:reference)
    end

    test "actor_label_method overrides the actor's name" do
      ApprovalEngine.config.actor_label_method = :display_name
      User.define_method(:display_name) { "Dana from Finance" }

      assert_match(/Dana from Finance/, body_of(activated, :plain))
    ensure
      User.remove_method(:display_name) if User.method_defined?(:display_name)
    end

    test "no url builder means no link, and a url builder produces one" do
      assert_no_match(/https?:/, body_of(activated, :plain), "the engine can't invent your routes")

      ApprovalEngine.config.approval_url_builder = ->(approval) { "https://example.test/approvals/#{approval.id}" }
      mail = activated

      assert_match(%r{https://example\.test/approvals/#{@approval.id}}, body_of(mail, :plain))
      assert_match(%r{https://example\.test/approvals/#{@approval.id}}, body_of(mail, :html))
    end

    test "mailer_from is applied only when configured" do
      assert_nil activated.from, "an unconfigured engine never invents a sender"

      ApprovalEngine.config.mailer_from = "approvals@example.test"

      assert_equal [ "approvals@example.test" ], activated.from
    end

    test "step_reminder says how long it has been waiting" do
      @step.update_column(:activated_at, 26.hours.ago)

      mail = NotificationMailer.step_reminder(@step.reload, to: "manager@example.test")

      assert_equal "Still waiting on you: Invoice ##{@invoice.id}", mail.subject
      assert_match(/26 hours/, body_of(mail, :plain))
    end

    test "changes_requested carries the approver's comment" do
      @step.request_changes!(by: @manager, comment: "Missing PO number")

      mail = NotificationMailer.changes_requested(@step.reload, to: "submitter@example.test")

      assert_equal "Changes requested: Invoice ##{@invoice.id}", mail.subject
      assert_match(/Missing PO number/, body_of(mail, :plain))
      assert_match(/Missing PO number/, body_of(mail, :html))
    end

    test "approval_rejected carries the reason when the ledger recorded one" do
      mail = NotificationMailer.approval_rejected(@approval, to: "submitter@example.test", reason: "over budget")

      assert_equal "Rejected: Invoice ##{@invoice.id}", mail.subject
      assert_match(/over budget/, body_of(mail, :plain))
    end

    test "subjects come from the locale file so a host can rewrite them" do
      subjects = [
        NotificationMailer.step_activated(@step, to: "a@example.test"),
        NotificationMailer.step_reminder(@step, to: "a@example.test"),
        NotificationMailer.step_reassigned(@step, to: "a@example.test"),
        NotificationMailer.changes_requested(@step, to: "a@example.test"),
        NotificationMailer.approval_approved(@approval, to: "a@example.test"),
        NotificationMailer.approval_rejected(@approval, to: "a@example.test")
      ].map(&:subject)

      assert_equal 6, subjects.uniq.size, "each notification says something different"
      subjects.each do |subject|
        assert_no_match(/translation missing/i, subject)
        assert_match(/Invoice ##{@invoice.id}/, subject)
      end
    end

    # "Drop a file in your app" is the whole answer to "how do I customise one
    # email", so prove it rather than assuming it. The fixture lives at
    # test/dummy/app/views/approval_engine/notification_mailer/ — the dummy is a
    # host application, and its view path is searched before the engine's.
    test "a host's own copy of a template wins over the engine's" do
      mail = NotificationMailer.step_reassigned(@step, to: "manager@example.test")

      assert_match(/HOST OVERRIDE SENTINEL/, mail.body.to_s)
    end

    # The documented pairing rule, pinned so it can't quietly stop being true:
    # Action Mailer takes an action's templates from the first view path that has
    # any of them, so the host's lone .text.erb above silences the engine's
    # .html.erb too. Override both formats together, or accept a single part.
    test "overriding one format of an action shadows the other" do
      mail = NotificationMailer.step_reassigned(@step, to: "manager@example.test")

      assert_not mail.multipart?
      assert_equal "text/plain", mail.mime_type
    end
  end
end
