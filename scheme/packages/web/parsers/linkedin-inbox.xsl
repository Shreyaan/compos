<?xml version="1.0" encoding="UTF-8"?>
<!-- The Recruiter inbox, calm: one conversation a line.

     The inbox draws a search box, a filter menu, a checkbox and two
     hover buttons on every card, and a ghost loader under all of it
     until the threads land. None of that is a conversation. What a
     conversation is: who it is with, when it last moved, whether the
     InMail was accepted, whether it is unread, and the last message.

     The card carries the whole last message, not a truncation, so the
     reading gives the page its detail for free and no thread is ever
     opened to fill one in. The body is normalized to a single line:
     the parser reads a conversation as three lines and a newline in
     the body would make it four. -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="html" encoding="UTF-8" omit-xml-declaration="yes"/>

  <xsl:template match="/">
    <html><body>
      <h1>Messages</h1>
      <xsl:variable name="cards" select="//*[@data-test-conversation-card-container]"/>
      <xsl:choose>
        <xsl:when test="$cards">
          <ul><xsl:apply-templates select="$cards"/></ul>
        </xsl:when>
        <!-- the ghost loader, a signed-out reading, or an empty inbox -->
        <xsl:otherwise>
          <p>No conversations on this page.</p>
        </xsl:otherwise>
      </xsl:choose>
    </body></html>
  </xsl:template>

  <xsl:template match="*[@data-test-conversation-card-container]">
    <xsl:variable name="href" select=".//a[@data-test-conversation-card]/@href"/>
    <xsl:variable name="when" select="normalize-space(.//*[@data-test-last-activity-time])"/>
    <xsl:variable name="status" select="normalize-space(.//*[@data-test-latest-reply-status])"/>
    <xsl:variable name="body" select="normalize-space(.//*[@data-test-message-item-body])"/>
    <li>
      <a href="{concat('https://www.linkedin.com', $href)}">
        <xsl:value-of select="normalize-space(.//*[@data-test-participant-name])"/>
      </a>
      <br/>
      <em>
        <xsl:value-of select="$when"/>
        <xsl:if test="$status"><xsl:text>, </xsl:text><xsl:value-of select="$status"/></xsl:if>
        <!-- the badge is the only thing on the card that says unread -->
        <xsl:if test=".//*[@data-test-unread-badge]"><xsl:text>, unread</xsl:text></xsl:if>
      </em>
      <xsl:if test="$body">
        <blockquote><xsl:value-of select="$body"/></blockquote>
      </xsl:if>
    </li>
  </xsl:template>
</xsl:stylesheet>
