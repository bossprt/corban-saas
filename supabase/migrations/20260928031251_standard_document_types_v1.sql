-- Standard document types of a consigned-credit correspondent (validation V1, owner asked for a ready list, 27/09/2026).
-- document_types is a shared reference list (read by every company, written only by migrations). Production had none,
-- so no document could be filed. Idempotent: an existing code is left as it is.
insert into public.document_types (code, name) values
  ('rg',                     'RG (documento de identidade)'),
  ('cnh',                    'CNH'),
  ('cpf',                    'CPF (quando o documento com foto não traz)'),
  ('selfie',                 'Selfie do cliente com o documento'),
  ('comprovante_residencia', 'Comprovante de residência'),
  ('contracheque',           'Contracheque / holerite'),
  ('extrato_beneficio',      'Extrato de pagamento do benefício (INSS)'),
  ('hiscon',                 'Histórico de empréstimos consignados (HISCON)'),
  ('extrato_bancario',       'Extrato bancário'),
  ('comprovante_conta',      'Comprovante da conta para crédito'),
  ('saldo_devedor',          'Saldo devedor / boleto de quitação (portabilidade e refin)'),
  ('contrato_assinado',      'Contrato assinado (CCB)'),
  ('autorizacao_desconto',   'Autorização de desconto / termo de adesão'),
  ('procuracao',             'Procuração ou termo de representante legal'),
  ('certidao',               'Certidão de nascimento ou casamento'),
  ('outro',                  'Outro documento')
on conflict (code) do nothing;
