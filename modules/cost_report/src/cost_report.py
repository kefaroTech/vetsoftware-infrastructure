"""Informe diario de costos de la cuenta AWS, publicado en Slack via SNS.

Cuenta cuanto costo el dia anterior, y los lunes tambien la semana que termino.
Sale por el topic de finops que ya escucha Amazon Q Developer.

Solo lee. La cifra es de la cuenta AWS completa, no de un ambiente: Cost Explorer
factura por cuenta, asi que mientras dev y prod compartan cuenta el total incluye
a los dos. Por eso el mensaje nombra la cuenta que consulto y no el ambiente.

Portado desde scripts/operations/cost-report.ps1, que corria por cron de GitHub
Actions. Ese cron llegaba con retrasos de dos a seis horas todos los dias, porque
los eventos programados de GitHub no estan garantizados. El reloj vive ahora en
EventBridge Scheduler y el informe llega a su hora.
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
from decimal import Decimal

import boto3

LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

# Cost Explorer atiende en un solo endpoint sin importar donde vivan los recursos.
COST_EXPLORER_REGION = "us-east-1"

# Cada pagina es un request facturado a USD 0.01. Con una cuenta y siete dias
# agrupados por servicio nunca deberia pasar de una, pero el tope evita que un
# token que no avanza se convierta en una factura.
MAX_PAGES = 5

TOP_SERVICES = 5


def _format_money(amount: Decimal) -> str:
    return f"USD {amount:,.2f}"


def _cost_by_service(start: str, end: str) -> list[dict]:
    """Tramos diarios de la ventana. Start es inclusivo y End exclusivo."""
    client = boto3.client("ce", region_name=COST_EXPLORER_REGION)
    results: list[dict] = []
    next_token: str | None = None

    for _ in range(MAX_PAGES):
        request = {
            "TimePeriod": {"Start": start, "End": end},
            "Granularity": "DAILY",
            "Metrics": ["UnblendedCost"],
            "GroupBy": [{"Type": "DIMENSION", "Key": "SERVICE"}],
        }
        if next_token:
            request["NextPageToken"] = next_token

        response = client.get_cost_and_usage(**request)
        results.extend(response.get("ResultsByTime", []))

        next_token = response.get("NextPageToken")
        if not next_token:
            return results

    raise RuntimeError(
        f"Cost Explorer devolvio mas de {MAX_PAGES} paginas; se corta para no seguir facturando requests."
    )


def _service_totals(results: list[dict]) -> dict[str, Decimal]:
    """Suma por servicio. Los que quedan en cero se descartan: una cuenta cualquiera
    reporta decenas y solo alargarian el mensaje."""
    totals: dict[str, Decimal] = {}

    for entry in results:
        for group in entry.get("Groups", []):
            amount = Decimal(group["Metrics"]["UnblendedCost"]["Amount"])
            if amount <= 0:
                continue

            service = group["Keys"][0]
            totals[service] = totals.get(service, Decimal(0)) + amount

    return totals


def _breakdown_lines(title: str, totals: dict[str, Decimal]) -> list[str]:
    """Titula el total y desglosa los servicios que de verdad pesan. El resto se
    resume en una linea: en una cuenta chica la cola son centavos que nadie lee."""
    total = sum(totals.values(), Decimal(0))
    lines = [f"*{title}* {_format_money(total)}"]
    if not totals:
        return lines

    ranked = sorted(totals.items(), key=lambda item: item[1], reverse=True)
    for service, amount in ranked[:TOP_SERVICES]:
        lines.append(f"• {service}: {_format_money(amount)}")

    rest = ranked[TOP_SERVICES:]
    if rest:
        rest_total = sum((amount for _, amount in rest), Decimal(0))
        lines.append(f"• otros {len(rest)} servicio(s): {_format_money(rest_total)}")

    return lines


def _publish(topic_arn: str, title: str, description: list[str]) -> None:
    """El formato es el de las custom notifications de Amazon Q Developer -version,
    source y content-, lo unico que ese integrador acepta de un emisor propio."""
    payload = {
        "version": "1.0",
        "source": "custom",
        "content": {
            "textType": "client-markdown",
            "title": title,
            "description": "\n".join(description),
        },
    }

    boto3.client("sns").publish(TopicArn=topic_arn, Message=json.dumps(payload))


def _reference_date(event: dict) -> dt.date:
    """Hoy en UTC, o la fecha del evento para reenviar a mano un dia que no salio."""
    as_of = (event or {}).get("as_of", "")
    if not as_of:
        return dt.datetime.now(dt.timezone.utc).date()

    try:
        return dt.datetime.strptime(as_of, "%Y-%m-%d").date()
    except ValueError as error:
        raise ValueError(f"as_of debe tener la forma yyyy-mm-dd; se recibio '{as_of}'.") from error


def handler(event, context):  # noqa: ARG001 - la firma la fija Lambda
    topic_arn = os.environ["TOPIC_ARN"]
    account_id = os.environ["ACCOUNT_ID"]

    reference = _reference_date(event)
    yesterday = reference - dt.timedelta(days=1)

    # Corriendo un lunes, los siete dias que terminan ayer son exactamente la
    # semana pasada de lunes a domingo. La ventana se pide una sola vez y el dia
    # se recorta de ahi: dos consultas costarian el doble sin agregar nada.
    is_weekly = reference.weekday() == 0
    window_start = yesterday - dt.timedelta(days=6) if is_weekly else yesterday

    start_label = window_start.isoformat()
    end_label = reference.isoformat()
    yesterday_label = yesterday.isoformat()

    LOGGER.info("Ventana consultada: %s a %s (UTC).", start_label, end_label)

    results = _cost_by_service(start_label, end_label)
    yesterday_results = [r for r in results if r["TimePeriod"]["Start"] == yesterday_label]

    if not yesterday_results:
        # Cost Explorer refresca al menos una vez cada 24 horas y tarda en poblar
        # los dias recien habilitados. Publicar "USD 0.00" cuando lo que pasa es
        # que no hay dato seria mentir, asi que se corta sin mensaje.
        LOGGER.warning("Cost Explorer todavia no tiene datos de %s; no se envia informe.", yesterday_label)
        return {"sent": False, "reason": "sin datos", "day": yesterday_label}

    daily_totals = _service_totals(yesterday_results)
    daily_total = sum(daily_totals.values(), Decimal(0))
    description = _breakdown_lines(f"Gasto del {yesterday_label}:", daily_totals)

    title = f":money_with_wings: Costo del {yesterday_label} - {_format_money(daily_total)}"
    if is_weekly:
        description.append("")
        description.extend(
            _breakdown_lines(
                f"Semana pasada ({start_label} a {yesterday_label}):",
                _service_totals(results),
            )
        )
        title = f":money_with_wings: Costo del {yesterday_label} y de la semana pasada"

    description.append("")
    description.append(
        f"_Cuenta {account_id}, costo sin combinar, fechas en UTC. "
        "Los cargos del periodo en curso son estimados._"
    )

    _publish(topic_arn, title, description)
    LOGGER.info("Informe publicado: %s el %s.", _format_money(daily_total), yesterday_label)

    return {"sent": True, "day": yesterday_label, "total": str(daily_total), "weekly": is_weekly}
