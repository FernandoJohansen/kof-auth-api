# kof-auth-api

Uma API de autenticação feita em [Kof](https://github.com/KofLang/Kof4j), a linguagem brasileira que compila para JVM, nativo e web.

Comecei este projeto para aprender Kof fazendo algo que eu conheço bem: segurança. A ideia era simples. Montar um login do jeito certo, com tudo que costuma faltar em APIs reais, e depois atacar a própria API para ver se as defesas aguentavam. Junto com o código vem um script, o `ataques.sh`, que faz exatamente isso. Na última execução, os 32 ataques foram bloqueados.

No caminho acabei encontrando alguns bugs na própria linguagem. Eles estão no fim deste README.

## Como rodar

Você precisa da Kof 0.5.0-beta, que dá para baixar na [página de releases](https://github.com/KofLang/Kof4j/releases). Ela já vem com a JVM embutida, então não precisa instalar Java.

```bash
export ADMIN_PASSWORD='uma-senha-admin-longa'
export JWT_SECRET="$(openssl rand -hex 32)"
export LANG=C.UTF-8
kof run main.kf
```

A `ADMIN_PASSWORD` precisa ter pelo menos 12 caracteres; sem ela, a API sobe sem nenhum admin. Sem o `JWT_SECRET`, ela gera um segredo novo a cada inicialização, o que funciona mas derruba todo mundo quando o servidor reinicia. O `LANG` é só para os acentos do log não saírem quebrados.

Com o servidor rodando, abra outro terminal e solte os ataques:

```bash
ADMIN_PASSWORD='uma-senha-admin-longa' ./ataques.sh
```

Rode contra um servidor recém-iniciado, porque o rate limit guarda estado entre execuções. No Windows, use o Git Bash.

Um detalhe: por enquanto só funciona no target JVM, porque a parte web com autenticação da Kof ainda não chegou no nativo nem no JS.

## O que a API faz

São seis rotas. Qualquer pessoa pode acessar `GET /health`, criar uma conta em `POST /register` e fazer login em `POST /login`, que devolve um token. Com o token no header `Authorization: Bearer ...`, dá para ver o próprio perfil em `GET /me` e sair em `POST /logout`. Por fim, `GET /admin/users` lista as contas, mas só para quem é admin.

Registro e login recebem o mesmo formato:

```json
{"username": "ana", "password": "Cavalo-Bateria-Grampo-9"}
```

## Como ela se defende

**As senhas nunca são guardadas.** O que fica salvo é um hash PBKDF2 com 600 mil iterações e sal, feito pela própria biblioteca da Kof. Na hora do cadastro, a API recusa senhas com menos de 12 caracteres, senhas que contêm o nome de usuário e as mais batidas da internet. Também existe um limite máximo de 128 caracteres, porque calcular hash de uma senha gigante custa caro e isso pode virar arma contra o servidor.

**Ela não entrega quem tem conta.** Se você erra a senha de um usuário que existe, recebe exatamente a mesma mensagem de quando o usuário nem existe. Só que isso não basta: se um caso responde mais rápido que o outro, um atacante descobre os usuários só cronometrando. Por isso, quando o usuário não existe, a API calcula o hash de qualquer jeito, contra um hash falso. No teste, as duas respostas levaram 0,166 s e 0,158 s.

**Chutar senha não compensa.** Cada IP pode fazer 60 requisições por minuto, e cada conta aceita 5 tentativas de login a cada 15 minutos. O limite por conta existe para pegar quem distribui o ataque em muitos IPs.

**O token é curto e difícil de falsificar.** Ele vale 15 minutos e é assinado com HMAC-SHA256. A API confere a assinatura, a validade, quem emitiu e para quem foi emitido. O `ataques.sh` tenta de tudo: mexer no conteúdo do token para virar admin, mandar um token sem assinatura (o velho truque do `alg: none`), assinar com um segredo chutado. Nada passa.

**Logout de verdade.** JWT não tem estado, então "sair" normalmente não invalida nada: o token continua valendo até expirar. Aqui, o logout guarda o hash do token numa lista de revogados até ele expirar sozinho. Guardo o hash, e não o token, para que quem olhar essa lista não encontre tokens prontos para usar.

**Tudo é fechado por padrão.** Só três rotas funcionam sem login, e a comparação é exata, com método e caminho. Assim, `/login/`, `/healthcheck` ou `/health/../me` não escapam por serem parecidos com uma rota pública. E qualquer rota nova que alguém criar já nasce protegida.

**Entrada desconfiada, saída cuidadosa.** Corpos acima de 4 KB são recusados. O nome de usuário só aceita letras minúsculas, números e `_ . -`, o que de quebra impede injeção de JSON e de linhas falsas no log. As respostas vão sempre com os headers de segurança do navegador e com `Cache-Control: no-store`, e o JSON é sempre gerado pela biblioteca, nunca montado na mão.

**Tudo que importa vai para o log.** Cadastro, login certo e errado, bloqueio por excesso de tentativas, acesso negado. Senha e token nunca aparecem lá.

Se você está se perguntando sobre CSRF: ficou desligado de propósito. Esse ataque depende de o navegador enviar a credencial sozinho, o que acontece com cookies. Aqui o token vai num header que só é enviado quando o cliente decide enviar.

## O que ainda falta

Este é um projeto de estudo, não algo para colocar em produção amanhã. Os pontos fracos que eu conheço:

As contas ficam em memória. Reiniciou, sumiu tudo. Além disso, o mapa não é seguro para acesso simultâneo, então dois cadastros com o mesmo nome no mesmo instante poderiam dar problema. O próximo passo natural é usar o `kof.db` com SQLite e uma restrição de nome único.

O bloqueio por conta tem um efeito colateral: qualquer um pode travar a conta de outra pessoa errando a senha dela cinco vezes. Dá para melhorar com atraso progressivo, CAPTCHA depois de algumas falhas ou bloqueando pelo par conta e IP.

O cadastro diz quando um nome já está em uso. É a troca comum entre segurança e usabilidade, e o rate limit segura a varredura em massa.

Atrás de um proxy, o limite por IP enxerga o IP do proxy, não o do cliente. Também não tem HTTPS: coloque um proxy reverso na frente ou use o `app.listenSecure` da Kof. E como a lista de revogados e os contadores de tentativa vivem na memória, rodar várias instâncias exigiria guardar isso num lugar compartilhado. Por fim, não há refresh token, então é preciso logar de novo a cada 15 minutos.

## O que encontrei na Kof

A Kof ainda está em beta, e construir algo real com ela revelou coisas que merecem issue no repositório oficial. Se for abrir alguma, confira antes se ela já não existe.

O mais sério é que a opção `publicPaths` do `app.security` não funciona junto com `auth: true`. Ela só é consultada em outro modo de autenticação, então com JWT toda rota passa a exigir token, inclusive a de login. Por isso fiz o controle de acesso num middleware próprio.

O segundo também é de segurança: essa mesma lista de rotas públicas compara por prefixo. Liberar `/public` acaba liberando `/publicAdmin` junto.

Os outros são menores. Um exemplo da documentação do `kof.web` não compila mais, porque coloca `true` num mapa que já tem textos e a Kof não aceita coleções com tipos misturados (passar `"true"` resolve). Um middleware que só devolve `null` compila, mas quebra toda requisição com erro 500. O `json.decode` deixa um campo ausente como `null` mesmo em um tipo que não aceita nulo, o que fura a null safety da linguagem; esta API confere isso na mão. E no target JVM, sem locale UTF-8 no sistema, os acentos saem como `?`, enquanto no nativo saem certos.