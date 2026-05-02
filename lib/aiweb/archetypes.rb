# frozen_string_literal: true

module Aiweb
  module Archetypes
    STOCK_TERMS = /주비서|주식|증권|투자|종목|시세|호가|주문|계좌|stock|stocks|trading|broker|brokerage|portfolio|quote|order/i.freeze
    ASSISTANT_TERMS = /assistant|chat|챗|채팅|대화|상담|비서|ai/i.freeze

    DEFINITIONS = {
      "landing-page" => {
        surface: "website",
        primary_user: "prospective visitor evaluating the offer",
        primary_interaction: "scan the offer and choose a clear call to action",
        not_surface: "app-dashboard",
        must_have_first_view: %w[hero_headline value_proposition primary_cta trust_signal],
        must_not_have: %w[unclear_cta fake_app_controls],
        semantic_risks: ["burying the value proposition below the fold", "presenting too many competing CTAs"],
        qa: ["First viewport communicates the offer and audience.", "Primary CTA is visible above the fold."]
      },
      "chat-assistant-webapp" => {
        surface: "app",
        primary_user: "person using the assistant to complete the requested domain task",
        primary_interaction: "ask a question or give an instruction in a chat input",
        not_surface: "landing-page",
        must_have_first_view: %w[chat_input conversation_history assistant_response_area context_panel safety_or_scope_notice],
        must_not_have: %w[landing_page_hero_as_primary_experience real_secret_or_token_capture unsafe_real_world_execution],
        semantic_risks: ["mistaking an app request for a marketing homepage", "showing assistant claims without scope or safety framing"],
        qa: ["First viewport includes a visible chat input.", "Sending or drafting a message has an assistant-response area to update.", "Safety/scope limits are visible when the domain is sensitive."]
      },
      "dashboard" => {
        surface: "app",
        primary_user: "operator monitoring and acting on live or mocked status",
        primary_interaction: "monitor key metrics and drill into a prioritized operational view",
        not_surface: "landing-page",
        must_have_first_view: %w[metric_cards primary_chart recent_activity filters_or_time_range],
        must_not_have: %w[marketing_only_hero disconnected_sample_numbers],
        semantic_risks: ["showing decorative charts without actionable state", "hiding filters or status context"],
        qa: ["Key metrics and at least one chart/table are visible above the fold.", "The dashboard exposes a time range, filter, or status context."]
      },
      "tool" => {
        surface: "app",
        primary_user: "person trying to complete the tool workflow immediately",
        primary_interaction: "enter input and receive an immediate generated, calculated, or transformed result",
        not_surface: "brochure-site",
        must_have_first_view: %w[input_form run_or_generate_control result_preview instructions],
        must_not_have: %w[cta_only_no_tool unavailable_core_action],
        semantic_risks: ["describing the tool instead of making it usable", "omitting the result preview state"],
        qa: ["Input, action control, and result preview are visible without navigation.", "Empty/error states explain how to get a valid result."]
      },
      "commerce" => {
        surface: "app",
        primary_user: "shopper evaluating products and purchase intent",
        primary_interaction: "browse products and move an item toward cart or checkout intent",
        not_surface: "generic-brand-page",
        must_have_first_view: %w[featured_products price_or_offer cart_or_checkout_entry trust_or_shipping_note],
        must_not_have: %w[missing_price_context fake_payment_capture],
        semantic_risks: ["collecting payment-like data before a real checkout exists", "hiding product availability or shipping trust cues"],
        qa: ["Featured product or offer cards include price/offer context.", "Cart/checkout intent is visible but unsafe fake payment capture is absent."]
      },
      "game" => {
        surface: "app",
        primary_user: "player starting or resuming a playable session",
        primary_interaction: "start or resume a playable interaction",
        not_surface: "landing-page",
        must_have_first_view: %w[play_area start_control score_or_progress instructions],
        must_not_have: %w[non_interactive_promo_only],
        semantic_risks: ["pitching the game instead of exposing play", "missing rules or progress feedback"],
        qa: ["Play area, start control, and instructions are visible above the fold.", "Score, progress, or state feedback is present."]
      }
    }.freeze

    KEYWORDS = {
      "chat-assistant-webapp" => [/chat/i, /assistant/i, /bot/i, /convers/i, /대화/, /챗/, /채팅/, /비서/, /상담/, /assistant/i],
      "dashboard" => [/dashboard/i, /admin/i, /analytics/i, /metrics?/i, /reporting/i, /대시보드/, /관리자/, /분석/, /지표/],
      "commerce" => [/commerce/i, /e-?commerce/i, /shop/i, /store/i, /cart/i, /checkout/i, /payment/i, /상품/, /쇼핑/, /스토어/, /장바구니/, /결제/, /커머스/],
      "game" => [/game/i, /playable/i, /score/i, /게임/, /플레이/, /점수/],
      "tool" => [/tool/i, /calculator/i, /generator/i, /converter/i, /planner/i, /tracker/i, /editor/i, /도구/, /계산기/, /생성기/, /변환기/, /플래너/, /추적/]
    }.freeze

    def self.classify(idea)
      text = idea.to_s
      key = if stock_assistant?(text)
              "chat-assistant-webapp"
            else
              matched = KEYWORDS.find { |_candidate, patterns| patterns.any? { |pattern| text.match?(pattern) } }
              matched ? matched.first : "landing-page"
            end

      intent = definition(key).merge(
        "schema_version" => 1,
        "original_intent" => text,
        "archetype" => key
      )
      stock_assistant?(text) ? stock_assistant_intent(intent) : intent
    end

    def self.definition(key)
      data = DEFINITIONS.fetch(key)
      data.each_with_object({}) do |(name, value), memo|
        memo[name.to_s] = value.is_a?(Array) ? value.dup : value
      end
    end

    def self.stock_assistant?(text)
      text.match?(STOCK_TERMS) && text.match?(ASSISTANT_TERMS)
    end

    def self.stock_assistant_intent(intent)
      intent.merge(
        "primary_user" => "individual domestic stock investor",
        "primary_interaction" => "ask stock questions in chat",
        "must_have_first_view" => %w[
          chat_input
          ai_answer_panel
          stock_status_panel
          order_preview
          safety_lock_reason
        ],
        "must_not_have" => %w[
          real_broker_order_execution
          real_account_token
          approval_key_capture
          landing_page_hero_as_primary_experience
        ],
        "semantic_risks" => [
          "mistaking app UI for marketing site",
          "implying investment advice without safety framing",
          "showing real trading capability"
        ]
      )
    end
  end
end
