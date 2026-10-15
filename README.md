# Folha: scanner iOS proprio, primeira implementacao

Estado: codigo-fonte inicial com testes e caminho de compilacao preparados.
NAO COMPILADO, NAO TESTADO NO IPHONE, SEM IPA ate haver um recibo de build aprovado.
Nao e uma copia binaria do CamScanner nem um aplicativo completo equivalente.

Nome provisório de produto: Folha. O codigo e novo e nao depende de executaveis,
recursos, modelos ou bibliotecas extraidos do CamScanner. As evidencias ficam
separadas, em `../analysis`, e nao devem entrar no pacote distribuido.

## Implementado no codigo

- Camera multipagina usando VisionKit e permissao solicitada pelo iOS.
- Importacao de fotos selecionadas pelo seletor do sistema.
- Deteccao de quadrilatero nas fotos importadas e correcao de perspectiva.
- Filtros independentes Original, Nitido, Cinza e Documento; rotacao.
- OCR local usando Vision, com idioma portugues/ingles quando suportado.
- Biblioteca local, busca no texto, renomeacao, ordem e remocao de paginas.
- PDF A4 multipagina com ajuste proporcional, camada de texto invisivel
  opcional, visualizacao e compartilhamento nativo.
- Fila serial de trabalho para processamento, fontes separadas de derivados,
  manifesto por documento e publicacao apos terminar a importacao.
- Falha de OCR aparece como aviso; nao impede guardar a imagem. Falha ao ler
  uma pagina impede publicar um PDF parcial.

## Escolhas e limites

O fluxo foi orientado por evidencia REA de filas, coordenadas, recorte,
melhoria de imagem e OCR. VisionKit/Vision/CoreImage sao substitutos escolhidos
por nos; NAO foram identificados como os mesmos algoritmos proprietarios.

- O recorte manual na captura e oferecido pela interface VisionKit. A edicao
  posterior deste prototipo oferece recorte automatico, nao editor livre dos cantos.
- Filtros nao equivalem a remocao neural de sombras, curvatura de livros ou dedos.
- OCR pode errar. Camada pesquisavel e alinhamento devem ser conferidos no aparelho.
- Imagens importadas preservam os bytes recebidos em `.source`. Capturas usam
  a imagem ja entregue pelo VisionKit, codificada em JPEG de alta qualidade;
  nao e o RAW da camera nem a fotografia anterior ao recorte do VisionKit.
- Nenhum login, API paga, sincronizacao, pagamento, assinatura ou watermark.
- Nao ha conversao para Word, importacao de PDF, scanner de livros, assinatura
  manuscrita, nuvem ou funcao de acrescentar paginas a documento existente ainda.
- Lotes muito grandes precisam de avaliacao de memoria; o seletor e a camera
  ainda entregam o lote antes de o processamento serial comecar.
- Pastas `.pending-*` de importacoes interrompidas ficam preservadas, mas ainda
  nao ha uma tela para recupera-las. Exportacoes antigas nao sao apagadas automaticamente.
- Remover pagina remove sua referencia, preservando o material de entrada.
- Nao ha equivalencia comprovada de qualidade com o CamScanner.

## Estrutura para xtool

Baseada no contrato oficial de SwiftPM + `xtool.yml` + `infoPath`:

https://github.com/xtool-org/xtool/tree/main/Examples/DemoSimple
https://github.com/xtool-org/xtool/blob/main/Documentation/xtool.docc/Control.md

Em host Linux/WSL/macOS com Swift e SDK Apple legitimamente obtido:

```sh
cd ios
xtool dev build
```

Este comando ainda nao foi executado. O Windows deste projeto nao tem WSL,
Swift ou SDK iOS preparados. Nao instalei esses componentes, nao reiniciei o
computador e nao fiz nova tentativa de autenticar a Apple.

Assinar e instalar o futuro IPA e uma etapa posterior, que exige uma identidade
de assinatura Apple. A interface e o processamento nao exigirao login do usuario.

## Verificacao pendente

O exportador recebeu correcao de conversao Unicode no nome do arquivo. Exportar
ou visualizar repetidamente um mesmo documento reutiliza seu arquivo gerado,
em vez de criar uma nova copia a cada toque.

Em um Mac com Xcode e XcodeGen, `bash scripts/build_unsigned.sh` gera o projeto,
executa os testes no simulador, compila para dispositivo e empacota um IPA SEM
ASSINATURA. O fluxo para se os testes falharem. Nenhuma senha Apple e usada.
`project.yml` e o caminho Xcode; `Package.swift` e `xtool.yml` permanecem como o
caminho xtool. O Info.plist comum nao contem placeholders de Xcode: o script
deriva `.build-ci/Info-Xcode.plist` a partir dele, mantendo uma fonte comum para
permissoes e metadados sem quebrar a configuracao do xtool.

O workflow foi apenas criado localmente. Publicacao em repositorio privado e
consumo da cota gratuita do GitHub aguardam a decisao solicitada ao usuario.
Nao ha autorizacao para cobranca extra, repositorio publico ou envio dos
arquivos proprietarios de referencia.

Compilacao real, captura/permissoes, cancelamento, importacao, fotos giradas,
recorte, portugues, documentos sem texto, ordem, falha de OCR, alinhamento da
camada pesquisavel, exportacao de todas as paginas, memoria e retomada apos
fechamento. Nenhum desses testes foi executado nesta etapa.
