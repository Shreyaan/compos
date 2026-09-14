<?xml version="1.0" encoding="UTF-8"?>
<!-- LinkedIn Recruiter, calm: the open projects, without the console.

     The whole-page reading gives the global nav, the search filters, the
     message and notification menus, a star button per row and a checkbox
     beside it. None of that is a project. What a project is: its name,
     the page it opens, the day it was created, and how many candidates
     stand in its pipeline.

     Recruiter answers a fetch with a script shell, so this site is
     registered to render: the reading is taken from a real background
     tab once the app has drawn itself. Every hook here is a data-test
     attribute, not a class. Recruiter ships new class names with every
     deploy and keeps the test hooks, so a reading keyed on them survives
     a redesign that a class selector would not. -->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:output method="html" encoding="UTF-8" omit-xml-declaration="yes"/>

  <xsl:template match="/">
    <html><body>
      <h1>Projects</h1>
      <xsl:variable name="projects" select="//li[@data-test-hp-project-list-item]"/>
      <xsl:choose>
        <xsl:when test="$projects">
          <ul><xsl:apply-templates select="$projects"/></ul>
        </xsl:when>
        <!-- a signed-out reading, or a page the app never finished drawing -->
        <xsl:otherwise>
          <p>No projects on this page.</p>
        </xsl:otherwise>
      </xsl:choose>
    </body></html>
  </xsl:template>

  <xsl:template match="li[@data-test-hp-project-list-item]">
    <xsl:variable name="href" select=".//a[@data-test-project-card-link]/@href"/>
    <xsl:variable name="created"
                  select="normalize-space(.//*[@data-test-project-lockup-meta-created-time])"/>
    <xsl:variable name="pipeline"
                  select="normalize-space(.//*[contains(@class, 'hp-project-list-item__pipeline-preview')])"/>
    <li>
      <a href="{concat('https://www.linkedin.com', $href)}">
        <xsl:value-of select="normalize-space(.//*[@data-test-project-name])"/>
      </a>
      <!-- a starred project is one the reader marked, and the star is the
           only thing on the row that says so -->
      <xsl:if test=".//*[@data-test-favorite-button-star-icon='filled']">
        <xsl:text> (favourite)</xsl:text>
      </xsl:if>
      <xsl:if test="$created or $pipeline">
        <br/>
        <em>
          <xsl:value-of select="$created"/>
          <xsl:if test="$created and $pipeline"><xsl:text>, </xsl:text></xsl:if>
          <xsl:value-of select="$pipeline"/>
        </em>
      </xsl:if>
    </li>
  </xsl:template>
</xsl:stylesheet>
