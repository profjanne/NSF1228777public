#!/usr/bin/python
# -*- coding: utf-8 -*-

import sqlite3 as lite
import sys

class Queryer(object):
    def __init__(self, dbpath):
        self._con = None
        try:
            self._con = lite.connect(dbpath)
            self._cur = self._con.cursor()
        except lite.Error, e:
            print "Error %s:" % e.args[0]
            sys.exit(1)

    def selectMany(self, query):
        try:
            self._cur.execute(query)
            output = self._cur.fetchall()
        except lite.Error, e:
            print "Error %s:" % e.args[0]
            sys.exit(1)

        return output

    def selectOne(self, query):
        try:
            self._cur.execute(query)
            output = self._cur.fetchone()
        except lite.Error, e:
            print "Error %s:" % e.args[0]
            sys.exit(1)

        return output

    def execute(self, query):
        try:
            self._cur.execute(query)
        except lite.Error, e:
            print "Error %s:" % e.args[0]
            self._con.rollback()
            sys.exit(1)
        else:
            self._con.commit()

    def closeDB(self):
        if self._con:
            self._con.close()

#q = Queryer('Smooth_Results/0-20/BEN/track-2-14-13-30.sq3')
