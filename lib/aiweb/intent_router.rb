# frozen_string_literal: true

require_relative "intent_router/profile_rules"

module Aiweb
  module IntentRouter
    ROUTES = {
      "ecommerce" => {
        surface: "website",
        recommended_skill: "ecommerce-category-page",
        recommended_design_system: "mobile-commerce",
        style_keywords: %w[mobile-first product-grid shoppable trustworthy touch-friendly],
        forbidden_design_patterns: [
          "fake scarcity or countdown pressure",
          "hidden prices or product availability",
          "forced account creation before cart review",
          "payment credential capture in mock flows"
        ]
      },
      "saas" => {
        surface: "website",
        recommended_skill: "saas-product-page",
        recommended_design_system: "conversion-saas",
        style_keywords: %w[product-led workflow-proof credible conversion-focused],
        forbidden_design_patterns: [
          "abstract AI platform claims without a concrete job",
          "decorative dashboards with nonsense metrics",
          "security or compliance claims without status",
          "pricing opacity without an evaluation path"
        ]
      },
      "service" => {
        surface: "website",
        recommended_skill: "service-business-site",
        recommended_design_system: "local-service-trust",
        style_keywords: %w[local-trust booking-ready practical warm mobile-contact],
        forbidden_design_patterns: [
          "hiding phone booking or directions in the footer",
          "generic about-us content before service details",
          "fake reviews ratings or credentials",
          "long intake forms before trust and fit are clear"
        ]
      },
      "premium" => {
        surface: "website",
        recommended_skill: "premium-landing-page",
        recommended_design_system: "luxury-editorial",
        style_keywords: %w[premium editorial restrained crafted high-trust],
        forbidden_design_patterns: [
          "generic innovation hero copy",
          "six equal feature cards with generic icons",
          "fake logos testimonials or unsourced proof",
          "gradient glassmorphism sparkle overload"
        ]
      },
      "fallback" => {
        surface: "website",
        recommended_skill: "premium-landing-page",
        recommended_design_system: "luxury-editorial",
        style_keywords: %w[clear focused trustworthy conversion-ready],
        forbidden_design_patterns: [
          "generic landing page without a specific audience",
          "competing first-screen calls to action",
          "invented proof or unsupported claims",
          "decorative UI that hides the core offer"
        ]
      }
    }.freeze

    KEYWORDS = {
      "ecommerce" => %w[
        ecommerce e-commerce commerce shop store storefront cart checkout buy purchase catalog catalogue collection drop merch retail preorder shipping returns
        쇼핑 쇼핑몰 스토어 상점 상품 제품 장바구니 결제 구매 판매 커머스 카탈로그 컬렉션 배송 반품 주문 예약구매
      ],
      "saas" => %w[
        saas app application webapp web-app portal software platform dashboard analytics crm b2b api developer automation workflow subscription trial demo signup sign-up onboarding integration integrations ai-tool ai tool
        SaaS 소프트웨어 플랫폼 대시보드 분석 자동화 워크플로우 구독 체험판 데모 회원가입 통합 개발자
      ],
      "service" => %w[
        clinic hospital dentist lawyer law restaurant cafe salon gym studio repair agency tutor school academy consultant consulting appointment booking quote local service services phone location hours
        병원 의원 치과 한의원 변호사 법률 식당 레스토랑 카페 미용실 헬스장 스튜디오 수리 대행사 과외 학원 상담 컨설팅 예약 견적 로컬 서비스 전화 위치 영업시간 진료 문의
      ],
      "premium" => %w[
        premium luxury boutique editorial high-end highend high-ticket landing landing-page landingpage private bespoke studio consultant consulting coaching course event brand portfolio architect interior hotel spa
        프리미엄 럭셔리 고급 부티크 에디토리얼 하이엔드 고가 랜딩 랜딩페이지 프라이빗 맞춤 브랜드 포트폴리오 컨설턴트 컨설팅 코칭 건축 인테리어 호텔 스파
      ]
    }.freeze

    SAFETY_TERMS = %w[
      finance financial medical healthcare health legal law insurance bank banking payment payments checkout account accounts order orders broker trading investment invest stock stocks loan tax regulated compliance credential token password pii phi
      hospital clinic dental dentist dermatology dermatologist orthopedics orthopedic ophthalmology ophthalmologist internal-medicine pediatrics pediatric ent physical-therapy physiotherapy therapy therapist care appointment
      금융 재무 의료 건강 병원 클리닉 클리닉웹사이트 진료 치료 도수치료 법률 법 변호사 보험 은행 결제 계좌 계정 주문 증권 투자 주식 대출 세금 세무 규제 개인정보 인증 토큰 비밀번호
      치과 피부과 한의원 의원 정형외과 내과 외과 안과 이비인후과 산부인과 소아과 정신건강의학과 신경외과 재활의학과 가정의학과 비뇨의학과 성형외과 요양병원 약국
    ].freeze

    APP_TERMS = %w[
      app application webapp web-app portal dashboard admin login auth account database realtime real-time live workflow tool calculator generator chat assistant
      앱 어플 애플리케이션 포털 대시보드 관리자 로그인 인증 계정 데이터베이스 실시간 도구 계산기 생성기 챗봇 비서
    ].freeze

    def self.route(idea)
      text = normalize_idea(idea)
      scores = scores_for(text)
      archetype = choose_archetype(scores)
      route = ROUTES.fetch(archetype)
      profile = recommended_profile(text, archetype)
      safety = sensitive?(text)

      {
        "schema_version" => 1,
        "original_intent" => text,
        "archetype" => archetype,
        "surface" => surface_for(text, route.fetch(:surface)),
        "recommended_skill" => route.fetch(:recommended_skill),
        "recommended_design_system" => route.fetch(:recommended_design_system),
        "recommended_profile" => profile,
        "framework" => framework_for(profile),
        "style_keywords" => route.fetch(:style_keywords).dup,
        "forbidden_design_patterns" => route.fetch(:forbidden_design_patterns).dup,
        "safety_sensitive" => safety
      }
    end

    def self.normalize_idea(idea)
      normalize_text(idea).strip.gsub(/\s+/, " ")
    end

    def self.scores_for(text)
      downcased = text.downcase
      KEYWORDS.transform_values do |terms|
        terms.count { |term| keyword_match?(downcased, term) }
      end
    end

    def self.choose_archetype(scores)
      precedence = %w[ecommerce saas service premium]
      strongest = scores.values.max.to_i
      return "fallback" unless strongest.positive?

      precedence.find { |name| scores.fetch(name, 0) == strongest }
    end

    def self.recommended_profile(text, archetype)
      ProfileRules.recommended_profile(text, archetype)
    end

    def self.framework_for(profile)
      ProfileRules.framework_for(profile)
    end

    def self.surface_for(text, default_surface)
      downcased = text.downcase
      APP_TERMS.any? { |term| keyword_match?(downcased, term) } ? "app" : default_surface
    end

    def self.sensitive?(text)
      downcased = text.downcase
      SAFETY_TERMS.any? { |term| keyword_match?(downcased, term) }
    end

    def self.keyword_match?(downcased_text, term)
      needle = normalize_text(term).downcase
      if ascii_word?(needle)
        downcased_text.match?(/(?<![a-z0-9])#{Regexp.escape(needle)}(?![a-z0-9])/)
      else
        downcased_text.include?(needle)
      end
    end

    def self.ascii_word?(term)
      term.match?(/\A[a-z0-9][a-z0-9-]*\z/i)
    end

    def self.normalize_text(value)
      value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
    rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
      value.to_s.encode(Encoding::UTF_8, value.to_s.encoding, invalid: :replace, undef: :replace, replace: "")
    end
  end
end
