# 05. 콘텐츠·브랜드·디자인 파이프라인

## 1. 핵심 원칙

웹사이트 완성도는 코드보다 다음에서 크게 결정된다.

- 누구에게 말하는가
- 어떤 문장으로 설득하는가
- 어떤 행동을 유도하는가
- 어떤 브랜드 인상을 주는가
- 그 인상이 디자인 시스템으로 일관되게 유지되는가

따라서 구현 전에 콘텐츠/브랜드/디자인 문서를 분리해 만든다.

## 2. 콘텐츠 파이프라인

```text
Idea
-> Product positioning
-> Messaging strategy
-> Page structure
-> Section copy
-> CTA strategy
-> SEO metadata
-> Content approval
```

산출물:

- `.ai-web/content.md`

필수 항목:

- Hero headline
- Subheadline
- Primary CTA
- Secondary CTA
- Problem section
- Benefits
- Features
- Social proof if applicable
- FAQ
- SEO title
- SEO description
- OG text

## 3. 브랜드 파이프라인

```text
Target audience
-> Brand personality
-> Tone of voice
-> Visual adjectives
-> Forbidden tone
-> Image/illustration direction
```

산출물:

- `.ai-web/brand.md`

필수 항목:

- 브랜드 성격 3~5개
- 말투 규칙
- 금지 표현
- 이미지 방향
- 감정 목표

## 4. 디자인 취향 캘리브레이션

디자인 생성 전 다음을 확정한다.

- 선호 무드 3개
- 비선호 무드 3개
- 컬러 방향
- 타이포그래피 방향
- layout density
- motion intensity
- 사진/일러스트/3D/타이포 중심 여부
- 참고 사이트
- 피해야 할 사이트/스타일

산출물:

- `.ai-web/design-brief.md`

## 5. GPT Image 2 / Claude Design 프롬프트

프롬프트는 다음 정보를 포함해야 한다.

- 제품 정의
- target audience
- brand personality
- page goal
- section structure
- visual style
- content excerpts
- responsive constraints
- forbidden patterns

프롬프트 목표:

```text
완성 코드 스펙 생성이 아니라 visual language 후보 생성
```

## 6. 디자인 후보 평가

각 후보는 다음 기준으로 평가한다.

| 기준 | 설명 |
|---|---|
| Brand fit | 브랜드/타깃과 맞는가 |
| Conversion clarity | CTA와 정보 구조가 명확한가 |
| Implementation feasibility | 실제 웹으로 구현 가능한가 |
| Responsiveness | 모바일로 자연스럽게 변환 가능한가 |
| Originality | 템플릿 느낌이 과하지 않은가 |
| System extractability | token/component rule로 추출 가능한가 |

## 7. DESIGN.md 변환 원칙

디자인 후보가 승인되면 이미지를 그대로 구현하지 않는다. 다음으로 변환한다.

```text
Visual reference
-> color tokens
-> typography scale
-> spacing scale
-> radius/shadow/elevation
-> layout grid
-> section recipes
-> component variants
-> motion rules
-> forbidden patterns
-> accessibility notes
```

산출물:

- `.ai-web/DESIGN.md`
- root `DESIGN.md`

## 8. DESIGN.md에 반드시 포함할 것

- 색상 토큰
- 폰트/타입 스케일
- spacing scale
- breakpoint 정책
- Button variants
- Card variants
- Form rules
- Section layout recipes
- Header/Footer rules
- Image treatment
- Motion rules
- 접근성 규칙
- 금지 규칙

## 9. 금지 규칙

- 디자인 이미지의 픽셀을 맹목적으로 복제 금지
- 임의 hex color 추가 금지
- 임의 spacing 추가 금지
- 필요 없는 component variant 추가 금지
- 페이지별로 다른 버튼/카드 스타일 생성 금지
- desktop만 보고 구현 금지



## 10. Content provenance

콘텐츠는 카피 품질뿐 아니라 출처와 권리도 기록해야 한다. `.ai-web/content.md`에는 다음을 포함한다.

- generated vs user-provided flag
- claim source
- owner approval
- legal/regulatory sensitivity
- image/license source
- testimonial permission
- prohibited claims

의료/법률/금융/투자성 claim은 source와 owner approval 없이는 Gate 1B를 통과할 수 없다.

## 11. Design candidate provenance

각 디자인 후보는 provider, tool, model, model snapshot, API surface, prompt, revised prompt, input/output asset, rights status를 기록한다. unknown rights는 Gate 2 blocker다.
