# frozen_string_literal: true

module Aiweb
  module IntentRouter
    module ProfileRules
      PROFILE_A_TERMS = %w[
        auth login sign-in signin account accounts user users admin database db dashboard live realtime real-time order orders payment payments checkout subscription regulated compliance hipaa pii phi broker trading medical legal finance financial insurance bank banking
        로그인 회원가입 계정 사용자 관리자 어드민 데이터베이스 실시간 라이브 주문 결제 구독 규제 컴플라이언스 개인정보 의료 법률 금융 보험 은행 증권 투자
      ].freeze

      PROFILE_D_TERMS = %w[
        content blog blogs article articles news resources resource guide guides magazine publication seo mdx docs documentation knowledge library newsletter
        콘텐츠 블로그 글 아티클 뉴스 자료 리소스 가이드 매거진 발행 출판 SEO 문서 지식 라이브러리 뉴스레터
      ].freeze

      PROFILE_S_TERMS = %w[
        supabase rls storage postgres postgresql magic-link magiclink upload uploads bucket buckets row-level-security
        수파베이스 스토리지 업로드 버킷
      ].freeze


      def self.recommended_profile(text, archetype)
        downcased = text.downcase
        return "S" if PROFILE_S_TERMS.any? { |term| Aiweb::IntentRouter.keyword_match?(downcased, term) }
        return "A" if PROFILE_A_TERMS.any? { |term| Aiweb::IntentRouter.keyword_match?(downcased, term) }
        return "C" if archetype == "ecommerce"
        return "D" if archetype != "service" && PROFILE_D_TERMS.any? { |term| Aiweb::IntentRouter.keyword_match?(downcased, term) }

        "B"
      end

      def self.framework_for(profile)
        case profile
        when "A"
          "Rails 8 + PostgreSQL + Hotwire/Turbo + Tailwind"
        when "B"
          "Astro + Cloudflare Pages + Tailwind"
        when "C"
          "Hybrid Rails main app + Cloudflare edge"
        when "D"
          "Astro + MDX/Content Collections + Cloudflare Pages + Tailwind"
        when "S"
          "Next.js App Router + Supabase SSR local scaffold"
        else
          "Astro + Cloudflare Pages + Tailwind"
        end
      end

    end
  end
end
