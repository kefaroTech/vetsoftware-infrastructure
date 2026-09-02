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

## Comentarios en el código

**El comentario es la última opción.** Antes van un nombre que diga lo que hace, un método
pequeño y un flujo que se lea de arriba abajo. Si un comentario existe porque el código
cuesta de leer, **arregla el código**.

- **Nunca narres QUÉ hace el código.** `# Crea el bucket` sobra: la línea de
  debajo ya lo dice. Igual `# Comprueba si existe` o `# Devuelve el resultado`.
- **Nunca guardes en un comentario** hallazgos de implementación, análisis, contexto de la
  tarea o del ticket, tu razonamiento, notas de depuración, narración histórica («antes este
  método…») ni la descripción del cambio que acabas de hacer. Eso va en la respuesta final,
  no en el código fuente. Las formas que más se cuelan: `# Añadido porque el ticket pide…`,
  `# Según mi análisis…`, `# Esto corrige el problema de…`, `# Esto asegura que…`.
- **Sí se gana su sitio cuando explica POR QUÉ existe algo no obvio**: una regla de negocio
  que no se deduce del código, el límite de una API externa, una restricción de
  compatibilidad, una suposición de concurrencia, una decisión de seguridad, una invariante,
  un workaround necesario, o código que parece incorrecto y es intencionadamente así.

```hcl
# ElastiCache no admite stop: apagar dev obliga a destruir y recrear, y eso
# cambia el endpoint y rompe REDIS_URL en silencio.
```

**Cierre de toda tarea de implementación:** repasa el `git diff`, borra los comentarios que
añadiste y no expliquen un porqué, y simplifica el código cuando el comentario solo existía
para descifrarlo. No toques comentarios previos ajenos al cambio, salvo que este los haya
vuelto incorrectos.

El objetivo no es cero comentarios: es que sean **excepcionales y valiosos** en vez de
rutinarios y descriptivos. La versión larga, con el alcance completo y las excepciones, está
en `.claude/rules/code-comments.md` del directorio de coordinación.

**Alcance en este repo.** Casi todo aquí es configuración (`.tf`, `.yml`, `.ps1`), donde un
comentario que explica un porqué —un límite del proveedor, un valor que no se puede cambiar
en caliente, el motivo de un `lifecycle` o de un `ignore_changes`— sí sirve y se queda. Lo
que no cambia es lo otro: ni narración de la tarea, ni hallazgos de la investigación, ni
descripción del cambio que acabas de hacer. `README.md` y `docs/` quedan fuera de esta regla.

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
