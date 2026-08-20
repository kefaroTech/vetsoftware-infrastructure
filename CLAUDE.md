# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this
repository.

Este repo es la infraestructura como código de VetSoftware (Terraform sobre AWS). Lo esencial
del qué y del porqué vive en `README.md` y en `docs/`; la política de ramas y commits, en
`AGENTS.md`, y es **obligatoria**. Referencias que se consultan más:

| Tema | Dónde |
|---|---|
| Política de ramas, commits y aprobación humana | `AGENTS.md` |
| Puerta de calidad (`fmt`, `validate`, `tflint`, `checkov`, `tftest`) | `docs/TERRAFORM_QUALITY_GATE.md` · `scripts/quality/terraform-gate.ps1` |
| Plan/apply por workflow y entornos | `docs/TERRAFORM_AUTOMATION.md` |
| Coste por entorno | `docs/COSTS.md` |
| Secretos (argumentos write-only, nunca en plan ni state) | `docs/GESTION_DE_SECRETOS.md` |
| Telemetría OTLP | `docs/TELEMETRIA_OTLP.md` |

`environments/dev` y `environments/prod` son **roots independientes**: se validan y planifican
por separado, y nunca se ejecuta `apply` desde una sesión — eso es de los workflows.

## Cierre obligatorio — nada abierto sin issue

**Regla dura del proyecto, sin excepciones y sin pedir permiso.** Todo lo que quede abierto al
terminar un trabajo en este repo —un hallazgo que no arreglas, deuda que descubres de paso, un
gate que no pudiste ejecutar, una decisión que necesita a un humano, un `TODO` que plantas, un
límite con el que topaste— **se crea como issue de GitHub antes de dar la respuesta final**.
Aplica igual a la sesión principal y a cualquier subagente. La sesión se cierra y se lleva el
contexto por delante; el issue no. Lo que solo vive en el informe se pierde: **si no está en
GitHub, no existe.**

Este repo es **`kefaroTech/vetsoftware-infrastructure`**. Si la causa del hallazgo está en la
aplicación y no en la infraestructura, el issue va allí: `kefaroTech/vetsoftware-backend`,
`kefaroTech/vetsoftware-admin-web` (consola de plataforma) o `kefaroTech/vetsoftware-public-web`
(app del tenant).

1. **Busca antes de crear**, para no duplicar:
   `gh issue list --repo <owner/repo> --state all --search "<palabras clave>"`.
   Si ya existe uno equivalente, añade lo nuevo con `gh issue comment <n>` y reporta ese número.
2. **Crea escribiendo el cuerpo en un fichero.** Las comillas de PowerShell destrozan los
   cuerpos largos; `--body-file` no:

   ```bash
   # escribe el cuerpo en un archivo temporal: las comillas de PowerShell
   # destrozan los cuerpos largos y --body-file lo evita
   gh issue create --repo kefaroTech/vetsoftware-infrastructure --title "<el problema, en una frase>" --body-file cuerpo.md
   ```

3. **El título nombra el problema, no la tarea**, en español, como el resto de issues del repo:
   «Los locks de proveedor generados en Windows rompen el gate en Linux», no «Regenerar los
   locks».
4. **El cuerpo lleva siempre**: qué encontraste · la evidencia en `archivo:línea` · por qué
   importa, con el escenario concreto de fallo (si no sabes decir qué se rompe y a quién, es una
   preferencia de estilo y no merece issue) · qué haría falta para cerrarlo · qué **no**
   comprobaste. Cierra el cuerpo con la línea
   `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
5. **Un hallazgo, un issue.** Nada de issues paraguas que mezclan cosas sin relación.
6. Lo que **sí** dejaste arreglado y verificado en esta misma sesión no lleva issue. Esto es para
   lo que queda vivo.

**Abrir un issue no es un commit ni un push**: no entra en la aprobación humana escrita que exige
`AGENTS.md` antes de tocar una rama. Créalo sin preguntar. Después enumera en tu salida cada
issue con su número y su URL.

Casos concretos de este repo que **siempre** llevan issue: un `plan` con destrucciones o
reemplazos que no se ejecuta, deriva detectada contra lo desplegado, un hallazgo de `checkov`
que se suprime con un `skip` (el issue justifica y da fecha de revisión), un lock de
proveedor generado en Windows que rompería el gate en Linux, y toda **escritura en AWS que
detectas y no ejecutas**. Nada de esto lo ve el build: se pierde si no queda escrito.
