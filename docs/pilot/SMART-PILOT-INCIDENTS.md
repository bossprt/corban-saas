# Registro de incidentes do piloto (Smart Promotora)

Preencha uma linha por incidente. O objetivo é permitir a correção rápida SEM expor dados sensíveis.

## O que anotar
| Campo | Exemplo |
|---|---|
| Data e hora (com fuso) | 2026-09-28 10:42 (America/Sao_Paulo) |
| Quem (perfil, não o nome completo) | operador |
| Rota / tela | /app/simulacoes |
| O que estava tentando fazer | criar simulação para cliente teste |
| O que apareceu (texto exato da mensagem) | "A tabela escolhida não está publicada para esta organização." |
| Referência do erro (tela "Algo não funcionou" mostra "Referência: ...") | 1234567890 |
| Print da tela | sim (sem CPF completo, sem senha, sem link de convite visíveis) |
| Gravidade | P0 travou o trabalho / P1 atrapalhou / P2 incômodo |

## NUNCA enviar ou registrar
Senha, link de convite ou de recuperação (contém token), chave de serviço, valores de variáveis de ambiente, CPF completo, dados bancários ou documentos de clientes. Para identificar um cliente use só as iniciais e o dia/hora do cadastro.

## Parar imediatamente e avisar (P0 de segurança)
- Alguém viu dados de outra organização.
- Alguém conseguiu marcar uma proposta como paga.
- Comissão apareceu para o operador.
- Um convite/senha foi exposto.
Ação: Equipe → desativar os acessos envolvidos, registrar o incidente e chamar o agente/ChatGPT. Ver `docs/deployment/PILOT-ROLLBACK.md`.

## Registro
| # | Data/hora | Perfil | Rota | Ação | Mensagem exata | Referência | Print | Gravidade | Situação |
|---|---|---|---|---|---|---|---|---|---|
| 1 | | | | | | | | | |
