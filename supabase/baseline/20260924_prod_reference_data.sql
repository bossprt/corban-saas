-- Global reference rows of production (no organization, no personal data), exported on 2026-09-24 from project
-- nhjfrcttzxnphhizlnmc. The schema baseline is structure-only, so a local database rebuilt from it lacks these rows;
-- load this file right after the baseline. Idempotent.

insert into public.commission_component_types (id, tech_key, name, sort_order, is_active, created_at) values
  ('b84ccd04-8586-450d-98f0-2143f58347b3', 'upfront', 'À Vista', 10, true, '2026-09-21 00:16:00.037276+00'),
  ('6cdeca6d-debf-4e35-a36a-f05ba98f210d', 'deferred', 'Diferido', 20, true, '2026-09-21 00:16:00.037276+00'),
  ('2af303fc-4f29-48ac-b4e3-a08af0b095c3', 'bonus_1', 'Bônus', 30, true, '2026-09-21 00:16:00.037276+00'),
  ('4ae1f3ba-35b1-4acb-a4ea-e049481ec77f', 'bonus_2', 'Bônus 2', 40, true, '2026-09-21 00:16:00.037276+00'),
  ('03cca1ac-045b-42ce-b5fc-7093425696a1', 'bonus_3', 'Bônus 3', 50, true, '2026-09-21 00:16:00.037276+00'),
  ('074a86c3-06e7-45fd-a6f0-c8646289b5b0', 'plastic', 'Plástico', 60, true, '2026-09-21 00:16:00.037276+00'),
  ('69bd6ac1-2f99-4017-bd88-2aaa5686d0ba', 'insurance_fixed', 'Seguro fixo', 70, true, '2026-09-21 00:16:00.037276+00')
on conflict do nothing;

insert into public.contract_types (id, tech_key, name, sort_order, is_active, created_at, organization_id, created_by, updated_at) values
  ('a0327e74-3792-4063-b8e3-3a99b9499401', 'novo', 'Novo', 10, true, '2026-09-20 13:30:17.203621+00', null, null, '2026-09-21 00:16:05.634651+00'),
  ('f0ffa7e1-5fd4-4a81-b169-ac16c37b0053', 'refinanciamento', 'Refinanciamento', 20, true, '2026-09-20 13:30:17.203621+00', null, null, '2026-09-21 00:16:05.634651+00'),
  ('1c0eeb8a-176a-4350-9b9d-a66e0f4ddc52', 'compra_de_divida', 'Compra de Dívida', 30, true, '2026-09-20 13:30:17.203621+00', null, null, '2026-09-21 00:16:05.634651+00'),
  ('f9903b88-616d-4e18-979b-7252a48a6440', 'portabilidade', 'Portabilidade', 40, true, '2026-09-20 13:30:17.203621+00', null, null, '2026-09-21 00:16:05.634651+00'),
  ('64bb6d82-8ece-4440-91cc-ba57dab602fd', 'refin_portabilidade', 'Refin/Portabilidade', 50, true, '2026-09-21 00:16:05.634651+00', null, null, '2026-09-21 00:16:05.634651+00')
on conflict do nothing;

insert into public.national_agreement_templates (id, tech_key, kind, name, uf, city, sort_order, is_active, created_at) values
  ('d2fb3bf8-25f2-4841-b7f3-e24c55011cca', 'gov-ac', 'state_government', 'Governo do Acre', 'AC', null, 1, true, '2026-09-20 13:30:17.203621+00'),
  ('7814fdb1-37c8-4bbb-90a3-84f30a836513', 'gov-al', 'state_government', 'Governo de Alagoas', 'AL', null, 2, true, '2026-09-20 13:30:17.203621+00'),
  ('86eb5d46-2ab2-43d9-be49-a84c7f5aac25', 'gov-ap', 'state_government', 'Governo do Amapá', 'AP', null, 3, true, '2026-09-20 13:30:17.203621+00'),
  ('4c0e6c9b-8f9b-493a-b61c-14cceca662ef', 'gov-am', 'state_government', 'Governo do Amazonas', 'AM', null, 4, true, '2026-09-20 13:30:17.203621+00'),
  ('c2183d02-aa9e-43be-b4a2-129562b75eb8', 'gov-ba', 'state_government', 'Governo da Bahia', 'BA', null, 5, true, '2026-09-20 13:30:17.203621+00'),
  ('0c21f6b4-86db-4276-b40f-7bfa76715352', 'gov-ce', 'state_government', 'Governo do Ceará', 'CE', null, 6, true, '2026-09-20 13:30:17.203621+00'),
  ('d92dbb63-9b8c-4ec8-ab76-5df7b4708ab8', 'gov-df', 'state_government', 'Governo do Distrito Federal', 'DF', null, 7, true, '2026-09-20 13:30:17.203621+00'),
  ('d501752c-4723-47e8-9809-1118ca2d76ab', 'gov-es', 'state_government', 'Governo do Espírito Santo', 'ES', null, 8, true, '2026-09-20 13:30:17.203621+00'),
  ('2568d438-3b69-4ba5-84f6-300c4c45d793', 'gov-go', 'state_government', 'Governo de Goiás', 'GO', null, 9, true, '2026-09-20 13:30:17.203621+00'),
  ('c36bdd4f-6b41-4b84-b040-223697177f4f', 'gov-ma', 'state_government', 'Governo do Maranhão', 'MA', null, 10, true, '2026-09-20 13:30:17.203621+00'),
  ('8c04f94a-0e2f-4efc-aefb-463b8edd5a21', 'gov-mt', 'state_government', 'Governo de Mato Grosso', 'MT', null, 11, true, '2026-09-20 13:30:17.203621+00'),
  ('6c80fadf-65a4-4498-bd75-142c2db016ab', 'gov-ms', 'state_government', 'Governo de Mato Grosso do Sul', 'MS', null, 12, true, '2026-09-20 13:30:17.203621+00'),
  ('75c57f8e-396b-45c5-8a43-f00651dd0f69', 'gov-mg', 'state_government', 'Governo de Minas Gerais', 'MG', null, 13, true, '2026-09-20 13:30:17.203621+00'),
  ('ec6f620d-325b-44d5-bee4-8621ab81561d', 'gov-pa', 'state_government', 'Governo do Pará', 'PA', null, 14, true, '2026-09-20 13:30:17.203621+00'),
  ('e0162e33-3017-4085-9ab9-ffff0b644094', 'gov-pb', 'state_government', 'Governo da Paraíba', 'PB', null, 15, true, '2026-09-20 13:30:17.203621+00'),
  ('8e47dd29-c009-44b8-b510-7b6eb459d1b6', 'gov-pr', 'state_government', 'Governo do Paraná', 'PR', null, 16, true, '2026-09-20 13:30:17.203621+00'),
  ('2b8fc6b8-3291-49f1-a26a-1798d7063b9f', 'gov-pe', 'state_government', 'Governo de Pernambuco', 'PE', null, 17, true, '2026-09-20 13:30:17.203621+00'),
  ('24abacd7-9fb8-42e4-a500-27134f45d2a2', 'gov-pi', 'state_government', 'Governo do Piauí', 'PI', null, 18, true, '2026-09-20 13:30:17.203621+00'),
  ('1930ecb4-6e44-4fa7-b21c-d0cceea63f7e', 'gov-rj', 'state_government', 'Governo do Rio de Janeiro', 'RJ', null, 19, true, '2026-09-20 13:30:17.203621+00'),
  ('c809fa69-3268-4365-94d7-bb22f2c2666d', 'gov-rn', 'state_government', 'Governo do Rio Grande do Norte', 'RN', null, 20, true, '2026-09-20 13:30:17.203621+00'),
  ('7f8d1611-e78f-4a8b-b617-73f708cd5016', 'gov-rs', 'state_government', 'Governo do Rio Grande do Sul', 'RS', null, 21, true, '2026-09-20 13:30:17.203621+00'),
  ('04ef2a78-e83e-49a0-b0ac-adcd28821ad1', 'gov-ro', 'state_government', 'Governo de Rondônia', 'RO', null, 22, true, '2026-09-20 13:30:17.203621+00'),
  ('fce75aa3-7599-4a13-9491-da570384be27', 'gov-rr', 'state_government', 'Governo de Roraima', 'RR', null, 23, true, '2026-09-20 13:30:17.203621+00'),
  ('41d1d124-330a-4343-b411-3c4a6e294356', 'gov-sc', 'state_government', 'Governo de Santa Catarina', 'SC', null, 24, true, '2026-09-20 13:30:17.203621+00'),
  ('e3d0e4c8-00f3-419a-b70d-a1e6ef51e35e', 'gov-sp', 'state_government', 'Governo de São Paulo', 'SP', null, 25, true, '2026-09-20 13:30:17.203621+00'),
  ('22f2e845-50b6-45da-b5c9-94aa6d15c7b2', 'gov-se', 'state_government', 'Governo de Sergipe', 'SE', null, 26, true, '2026-09-20 13:30:17.203621+00'),
  ('1d4ca9bc-10d9-4358-b450-f536f13397c8', 'gov-to', 'state_government', 'Governo do Tocantins', 'TO', null, 27, true, '2026-09-20 13:30:17.203621+00'),
  ('b6df644d-5260-418f-90dc-0a8b85284e59', 'pref-rio-branco', 'capital_city_hall', 'Prefeitura de Rio Branco', 'AC', 'Rio Branco', 101, true, '2026-09-20 13:30:17.203621+00'),
  ('6ed7169a-8c20-4f01-b763-06e42fc3cdca', 'pref-maceio', 'capital_city_hall', 'Prefeitura de Maceió', 'AL', 'Maceió', 102, true, '2026-09-20 13:30:17.203621+00'),
  ('c592d168-3f48-43cc-aca9-f019e9163027', 'pref-macapa', 'capital_city_hall', 'Prefeitura de Macapá', 'AP', 'Macapá', 103, true, '2026-09-20 13:30:17.203621+00'),
  ('20c7a992-9cfd-48e6-bfdb-4ebb1a12a3e7', 'pref-manaus', 'capital_city_hall', 'Prefeitura de Manaus', 'AM', 'Manaus', 104, true, '2026-09-20 13:30:17.203621+00'),
  ('aceaf938-277e-4814-9ffa-f26efefc9258', 'pref-salvador', 'capital_city_hall', 'Prefeitura de Salvador', 'BA', 'Salvador', 105, true, '2026-09-20 13:30:17.203621+00'),
  ('bfa0f59d-8afb-4459-91eb-10e1e8ef2ff0', 'pref-fortaleza', 'capital_city_hall', 'Prefeitura de Fortaleza', 'CE', 'Fortaleza', 106, true, '2026-09-20 13:30:17.203621+00'),
  ('46d9195f-1d99-4c72-82d6-7c097b085ed2', 'pref-vitoria', 'capital_city_hall', 'Prefeitura de Vitória', 'ES', 'Vitória', 107, true, '2026-09-20 13:30:17.203621+00'),
  ('0adf0878-9e0f-42f2-86c3-ddcd644a0fb1', 'pref-goiania', 'capital_city_hall', 'Prefeitura de Goiânia', 'GO', 'Goiânia', 108, true, '2026-09-20 13:30:17.203621+00'),
  ('028e517e-e471-4c5c-8b9d-e09a43890a01', 'pref-sao-luis', 'capital_city_hall', 'Prefeitura de São Luís', 'MA', 'São Luís', 109, true, '2026-09-20 13:30:17.203621+00'),
  ('f5fd5a05-0f52-47f3-bbd9-77f8836ca6c0', 'pref-cuiaba', 'capital_city_hall', 'Prefeitura de Cuiabá', 'MT', 'Cuiabá', 110, true, '2026-09-20 13:30:17.203621+00'),
  ('17b6303e-a08f-4004-846b-c4298f6dc47b', 'pref-campo-grande', 'capital_city_hall', 'Prefeitura de Campo Grande', 'MS', 'Campo Grande', 111, true, '2026-09-20 13:30:17.203621+00'),
  ('6dd9b3e9-c707-4138-b789-3d83e2e776aa', 'pref-belo-horizonte', 'capital_city_hall', 'Prefeitura de Belo Horizonte', 'MG', 'Belo Horizonte', 112, true, '2026-09-20 13:30:17.203621+00'),
  ('c5c4b6a1-888f-426d-a748-134594db9d5c', 'pref-belem', 'capital_city_hall', 'Prefeitura de Belém', 'PA', 'Belém', 113, true, '2026-09-20 13:30:17.203621+00'),
  ('79552cfe-0935-4375-81cd-d789b6ecc45e', 'pref-joao-pessoa', 'capital_city_hall', 'Prefeitura de João Pessoa', 'PB', 'João Pessoa', 114, true, '2026-09-20 13:30:17.203621+00'),
  ('975e9fcf-1cd9-47ca-b596-011bae55690a', 'pref-curitiba', 'capital_city_hall', 'Prefeitura de Curitiba', 'PR', 'Curitiba', 115, true, '2026-09-20 13:30:17.203621+00'),
  ('706d0764-2a81-49b5-9836-a75c16defb66', 'pref-recife', 'capital_city_hall', 'Prefeitura do Recife', 'PE', 'Recife', 116, true, '2026-09-20 13:30:17.203621+00'),
  ('5e26b191-46df-4f57-9fa7-94ca7ec07726', 'pref-teresina', 'capital_city_hall', 'Prefeitura de Teresina', 'PI', 'Teresina', 117, true, '2026-09-20 13:30:17.203621+00'),
  ('efba0b26-88d8-4f0c-8a01-f6be089f5117', 'pref-rio-de-janeiro', 'capital_city_hall', 'Prefeitura do Rio de Janeiro', 'RJ', 'Rio de Janeiro', 118, true, '2026-09-20 13:30:17.203621+00'),
  ('cdace751-b731-4048-9c14-f5ed27baf15d', 'pref-natal', 'capital_city_hall', 'Prefeitura de Natal', 'RN', 'Natal', 119, true, '2026-09-20 13:30:17.203621+00'),
  ('64a5ae53-3dc7-4742-bce5-2b0783ac30db', 'pref-porto-alegre', 'capital_city_hall', 'Prefeitura de Porto Alegre', 'RS', 'Porto Alegre', 120, true, '2026-09-20 13:30:17.203621+00'),
  ('e2b679d6-47da-4a21-ba00-f6bf5410a3c2', 'pref-porto-velho', 'capital_city_hall', 'Prefeitura de Porto Velho', 'RO', 'Porto Velho', 121, true, '2026-09-20 13:30:17.203621+00'),
  ('eb46dd4b-273e-441b-a9a4-0ade43ad5bc2', 'pref-boa-vista', 'capital_city_hall', 'Prefeitura de Boa Vista', 'RR', 'Boa Vista', 122, true, '2026-09-20 13:30:17.203621+00'),
  ('469feae6-3f6a-4364-9833-e216a3b59f70', 'pref-florianopolis', 'capital_city_hall', 'Prefeitura de Florianópolis', 'SC', 'Florianópolis', 123, true, '2026-09-20 13:30:17.203621+00'),
  ('f0bed17f-7683-42de-b011-e98b22131ed8', 'pref-sao-paulo', 'capital_city_hall', 'Prefeitura de São Paulo', 'SP', 'São Paulo', 124, true, '2026-09-20 13:30:17.203621+00'),
  ('25b1ffc1-9b8e-4465-b0d8-6a1bcd7edee2', 'pref-aracaju', 'capital_city_hall', 'Prefeitura de Aracaju', 'SE', 'Aracaju', 125, true, '2026-09-20 13:30:17.203621+00'),
  ('b38dac7c-18a8-47fe-9930-9ae4104bfa07', 'pref-palmas', 'capital_city_hall', 'Prefeitura de Palmas', 'TO', 'Palmas', 126, true, '2026-09-20 13:30:17.203621+00')
on conflict do nothing;
