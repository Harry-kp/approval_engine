require "test_helper"

module ApprovalEngine
  module Admin
    class TriggerRulesControllerTest < ActionDispatch::IntegrationTest
      include Engine.routes.url_helpers
      include ApprovalEngine::ApprovalFixtures

      setup do
        ApprovalEngine.config.admin_enabled = true
        @template = create_template(
          event: "invoice.created",
          steps: [ { name: "Manager", group: "manager" } ],
          name: "High-value invoice"
        )
      end

      teardown { ApprovalEngine.config.admin_enabled = true }

      # The dummy Invoice exposes `amount` as :decimal and `department` as
      # :string, which is why the casting assertions below expect 10_000.0.
      def post_rule(condition_params)
        post admin_track_template_trigger_rules_path(@template),
             params: { trigger_rule: {
               tenant_id: TENANT, event_name: "invoice.created", priority: 0, active: "1"
             }.merge(condition_params) }
      end

      test "new offers the exposed attributes as fields" do
        get new_admin_track_template_trigger_rule_path(@template)

        assert_response :success
        assert_select "optgroup[label=?]", "Invoice"
        assert_select "option[value=?]", "amount"
        assert_select "option[value=?]", "department"
      end

      test "new offers the conventional event names" do
        get new_admin_track_template_trigger_rule_path(@template)

        assert_response :success
        assert_select "datalist option[value=?]", "invoice.created"
        assert_select "datalist option[value=?]", "invoice.updated"
      end

      test "create builds JSON Logic from the simple form" do
        assert_difference -> { TriggerRule.count }, 1 do
          post_rule(condition_mode: "simple", conditions: [ { field: "amount", operator: "gt", value: "10000" } ])
        end

        assert_redirected_to admin_track_template_path(@template)
        assert_equal({ ">" => [ { "var" => "amount" }, 10_000.0 ] }, TriggerRule.last.condition)
      end

      test "create ANDs several rows" do
        post_rule(condition_mode: "simple", conditions: [
          { field: "amount", operator: "gt", value: "10000" },
          { field: "department", operator: "not_eq", value: "IT" }
        ])

        condition = TriggerRule.last.condition
        assert_equal 2, condition["and"].size
        assert_equal({ ">" => [ { "var" => "amount" }, 10_000.0 ] }, condition["and"].first)
        assert_equal({ "!=" => [ { "var" => "department" }, "IT" ] }, condition["and"].last)
      end

      test "create drops blank rows" do
        post_rule(condition_mode: "simple", conditions: [
          { field: "amount", operator: "gt", value: "10000" },
          { field: "", operator: "eq", value: "" },
          { field: "", operator: "eq", value: "" }
        ])

        # A bare comparison, not an `and` of one.
        assert_equal({ ">" => [ { "var" => "amount" }, 10_000.0 ] }, TriggerRule.last.condition)
      end

      test "create rejects a simple form with no conditions" do
        assert_no_difference -> { TriggerRule.count } do
          post_rule(condition_mode: "simple", conditions: [ { field: "", operator: "eq", value: "" } ])
        end

        assert_response :unprocessable_entity
        assert_select ".ae-errors"
      end

      test "create stores raw JSON Logic" do
        raw = { "or" => [ { ">" => [ { "var" => "amount" }, 50_000 ] },
                          { "==" => [ { "var" => "department" }, "Legal" ] } ] }

        assert_difference -> { TriggerRule.count }, 1 do
          post_rule(condition_mode: "advanced", condition_json: raw.to_json)
        end

        assert_equal raw, TriggerRule.last.condition
      end

      test "create rejects raw JSON that is not an object" do
        # Regression-critical: JSON Logic evaluates a non-object as a literal, so
        # such a rule would match every event of its name.
        assert_no_difference -> { TriggerRule.count } do
          post_rule(condition_mode: "advanced", condition_json: "[1,2]")
        end

        assert_response :unprocessable_entity
        assert_select ".ae-errors", /must be a JSON Logic object/
      end

      test "create rejects malformed JSON" do
        assert_no_difference -> { TriggerRule.count } do
          post_rule(condition_mode: "advanced", condition_json: "{")
        end

        assert_response :unprocessable_entity
        assert_select ".ae-errors", /isn't valid JSON/
      end

      test "create rejects a raw condition larger than the cap" do
        assert_no_difference -> { TriggerRule.count } do
          post_rule(condition_mode: "advanced",
                    condition_json: { "==" => [ { "var" => "department" }, "x" * 9_000 ] }.to_json)
        end

        assert_response :unprocessable_entity
        assert_select ".ae-errors", /too large/
      end

      test "edit round-trips a simple condition into the triple" do
        rule = create_rule(template: @template, condition: { ">" => [ { "var" => "amount" }, 10_000 ] })

        get edit_admin_track_template_trigger_rule_path(@template, rule)

        assert_response :success
        assert_select "option[selected][value=?]", "amount"
        assert_select "option[selected][value=?]", "gt"
        assert_select "input[name=?][value=?]", "trigger_rule[conditions][][value]", "10000"
        assert_select "#ae-cond-simple[checked]"
      end

      test "edit falls back to the raw editor for a condition the simple form can't represent" do
        rule = create_rule(template: @template, condition: {
          "or" => [ { ">" => [ { "var" => "amount" }, 50_000 ] },
                    { "==" => [ { "var" => "department" }, "Legal" ] } ]
        })

        get edit_admin_track_template_trigger_rule_path(@template, rule)

        assert_response :success
        assert_select "#ae-cond-advanced[checked]"
        assert_select "textarea[name=?]", "trigger_rule[condition_json]"
        # The simple inputs are disabled, so an accidental save can't silently
        # replace a hand-written rule with an empty one.
        assert_select "input[name=?][disabled]", "trigger_rule[conditions][][value]"
        assert_select ".ae-hint", /more than the simple editor can show/
      end

      test "edit warns when a rule reads an attribute nobody exposes" do
        rule = create_rule(template: @template, condition: { ">" => [ { "var" => "vendor_score" }, 3 ] })

        get edit_admin_track_template_trigger_rule_path(@template, rule)

        assert_response :success
        assert_select "optgroup[label=?]", "Not exposed — this rule can never match" do
          assert_select "option[selected][value=?]", "vendor_score"
        end
      end

      test "update rewrites the condition" do
        rule = create_rule(template: @template, condition: { ">" => [ { "var" => "amount" }, 1 ] })

        patch admin_track_template_trigger_rule_path(@template, rule),
              params: { trigger_rule: { tenant_id: TENANT, event_name: "invoice.created", priority: 5, active: "1",
                                        condition_mode: "simple",
                                        conditions: [ { field: "amount", operator: "gte", value: "25000" } ] } }

        assert_redirected_to admin_track_template_path(@template)
        rule.reload
        assert_equal({ ">=" => [ { "var" => "amount" }, 25_000.0 ] }, rule.condition)
        assert_equal 5, rule.priority
      end

      test "destroy removes the rule" do
        rule = create_rule(template: @template, condition: { ">" => [ { "var" => "amount" }, 1 ] })

        assert_difference -> { TriggerRule.count }, -1 do
          delete admin_track_template_trigger_rule_path(@template, rule)
        end

        assert_redirected_to admin_track_template_path(@template)
      end

      # The sibling delete path refuses this, and reconcile_rules! deactivates
      # rather than destroys, both because the provenance FK is on_delete:
      # :nullify — a hard delete silently blanks "which rule started this?" on
      # every approval the rule ever routed.
      test "destroy refuses a rule that has already routed approvals" do
        create_user(role: :manager)
        rule = create_rule(template: @template, condition: { ">" => [ { "var" => "amount" }, 1 ] })
        invoice = Invoice.create!(tenant_id: TENANT, amount: 20_000, department: "IT")
        approval = invoice.run_approval!(event: "invoice.created", tenant_id: TENANT)
        assert_equal rule, approval.trigger_rule

        assert_no_difference -> { TriggerRule.count } do
          delete admin_track_template_trigger_rule_path(@template, rule)
        end

        assert_redirected_to admin_track_template_path(@template)
        assert_match(/Untick Active/, flash[:alert])
        assert_equal rule, approval.reload.trigger_rule
      end

      test "index orders rules the way the evaluator resolves them" do
        create_rule(template: @template, condition: { ">" => [ { "var" => "amount" }, 1 ] }, priority: 0)
        create_rule(template: @template, condition: { ">" => [ { "var" => "amount" }, 99 ] }, priority: 10)

        get admin_trigger_rules_path

        assert_response :success
        priorities = css_select("tbody tr td:nth-child(2)").map { |cell| cell.text.strip }
        assert_equal %w[10 0], priorities
      end

      test "index renders a human summary of each condition" do
        create_rule(template: @template, condition: { ">" => [ { "var" => "amount" }, 10_000 ] })

        get admin_trigger_rules_path

        assert_response :success
        assert_select "td", "amount is greater than 10000"
      end

      test "actions 404 while the admin is disabled" do
        rule = create_rule(template: @template, condition: { ">" => [ { "var" => "amount" }, 1 ] })
        ApprovalEngine.config.admin_enabled = false

        get admin_trigger_rules_path
        assert_response :not_found

        get new_admin_track_template_trigger_rule_path(@template)
        assert_response :not_found

        post_rule(condition_mode: "simple", conditions: [ { field: "amount", operator: "gt", value: "1" } ])
        assert_response :not_found

        delete admin_track_template_trigger_rule_path(@template, rule)
        assert_response :not_found
        assert TriggerRule.exists?(rule.id)
      end
    end
  end
end
